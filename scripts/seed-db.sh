#!/usr/bin/env bash
# seed-db.sh — put the four service databases into a known state for demos and
# chaos experiments (docs/chaos-experiments/). Invoked via `just seed-db <scenario>`.
#
# SQL runs as the postgres superuser via `kubectl exec` on each CloudNativePG
# primary (peer auth over the local socket) — no port-forwards, no credentials.
#
# Scenarios:
#   status    read-only: row counts, route occupancy, non-terminal orders
#   clean     wipe all money-path data; restore the two migration-seed routes
#             (V2__seed_demo_routes.sql: ...0001 @ 100 seats, ...00ce @ 2 seats)
#   normal    clean + a realistic catalog (6 extra routes) + 40 historical
#             CONFIRMED orders, consistent across all four DBs (I1/I2/I3 hold)
#   ce-1      clean + throughput route ...0001 at SEATS (default 5000)
#   ce-2      clean + contention route ...00ce at SEATS (default 2)
#   ce-3      clean + throughput route ...0001 at SEATS (default 5000)
#   ce-4      clean + throughput route ...0001 at SEATS (default 5000)
#   ce-5      clean + throughput route ...0001 at SEATS (default 5000)
#
# Options (env vars):
#   SEATS=<n>   capacity for the scenario's target route
#   FORCE=1     skip the confirmation prompt (anything except `status` wipes data)
#   NS=<ns>     namespace (default eurotransit)
#
# Caveats:
#   - Run with NO load in flight: wiping tables under active consumers produces
#     confusing FK/optimistic-lock errors, not data corruption.
#   - Kafka offsets are untouched: already-consumed events are not re-delivered,
#     so wiped processed_events rows cannot cause double-processing.
#   - Catalog serves browse from an in-memory advisory cache (app ADR 0006) that
#     only loads at startup (hydrates from Inventory's GET /inventory/routes, then
#     applies inventory-reserved events from latest). A SQL reseed is invisible to
#     it until you restart Catalog: `just catalog-refresh` (app-repo #33 made the
#     restart convergent; before it, restart replayed-from-earliest and re-diverged).
#     Inventory needs no restart — it reads inventorydb live. The k6 harnesses pass
#     ROUTE_ID directly, so experiments are unaffected.

set -euo pipefail

NS="${NS:-eurotransit}"
SEATS="${SEATS:-}"

# Route ids fixed by V2__seed_demo_routes.sql and the k6 harnesses (app repo).
BIG_ROUTE='00000000-0000-0000-0000-000000000001'   # k6 baseline.js default
TINY_ROUTE='00000000-0000-0000-0000-0000000000ce'  # k6 ce2-contention.js default

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# sql <cnpg-cluster> <database>  — pipe SQL into the current primary
sql() {
  local cluster="$1" db="$2" pod
  pod="$(kubectl get pod -n "$NS" \
        -l "cnpg.io/cluster=${cluster},cnpg.io/instanceRole=primary" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -z "$pod" ]; then
    echo "ERROR: no primary pod found for CNPG cluster '${cluster}' in ns '${NS}'" >&2
    exit 1
  fi
  kubectl exec -i -n "$NS" "$pod" -c postgres -- \
    psql -qX -v ON_ERROR_STOP=1 -U postgres -d "$db"
}

confirm() {
  [ "${FORCE:-0}" = "1" ] && return 0
  echo "kubectl context: $(kubectl config current-context)"
  echo "This WIPES money-path data in all four ${NS} databases."
  read -r -p "Type 'yes' to continue: " answer
  [ "$answer" = "yes" ] || { echo "Aborted."; exit 1; }
}

# ---------------------------------------------------------------------------
# Building blocks
# ---------------------------------------------------------------------------

# wipe_all <big_seats> <tiny_seats> — truncate everything, restore demo routes
wipe_all() {
  local big_seats="$1" tiny_seats="$2"

  echo "-- inventorydb: wipe + demo routes (${BIG_ROUTE##*-} @ ${big_seats}, ${TINY_ROUTE##*-} @ ${tiny_seats})"
  sql eurotransit-inventory-db inventorydb <<SQL
BEGIN;
TRUNCATE reservations, processed_events;
DELETE FROM routes;
INSERT INTO routes (id, origin, destination, departure_time, total_seats, available_seats, price, version)
VALUES
  ('${BIG_ROUTE}',  'Turin', 'Milan',  NOW() + INTERVAL '7 days', ${big_seats},  ${big_seats},  19.90, 0),
  ('${TINY_ROUTE}', 'Rome',  'Naples', NOW() + INTERVAL '7 days', ${tiny_seats}, ${tiny_seats}, 24.50, 0);
COMMIT;
SQL

  echo "-- ordersdb: wipe"
  sql eurotransit-orders-db ordersdb <<'SQL'
TRUNCATE orders, processed_events, idempotency_records;
SQL

  echo "-- paymentsdb: wipe"
  sql eurotransit-payments-db paymentsdb <<'SQL'
TRUNCATE payment_intents, processed_events;
SQL

  echo "-- notificationsdb: wipe"
  sql eurotransit-notifications-db notificationsdb <<'SQL'
TRUNCATE sent_notifications;
SQL
}

# seed_history — 40 CONFIRMED historical orders, deterministic ids
# (md5('seed-order-'||i)::uuid), consistent across all four DBs so the CE
# verification queries (I1/I2/I3, cross-DB join, single payment intent,
# notification per order) all hold on the seeded state.
seed_history() {
  echo "-- inventorydb: 6 catalog routes + 40 historical reservations"
  sql eurotransit-inventory-db inventorydb <<'SQL'
BEGIN;
INSERT INTO routes (id, origin, destination, departure_time, total_seats, available_seats, price, version)
VALUES
  ('00000000-0000-0000-0000-000000000002', 'Paris',  'Lyon',      NOW() + INTERVAL '2 days', 180, 180, 39.90, 0),
  ('00000000-0000-0000-0000-000000000003', 'Milan',  'Rome',      NOW() + INTERVAL '3 days', 320, 320, 49.90, 0),
  ('00000000-0000-0000-0000-000000000004', 'Vienna', 'Prague',    NOW() + INTERVAL '4 days', 140, 140, 29.90, 0),
  ('00000000-0000-0000-0000-000000000005', 'Berlin', 'Munich',    NOW() + INTERVAL '5 days', 200, 200, 44.50, 0),
  ('00000000-0000-0000-0000-000000000006', 'Madrid', 'Barcelona', NOW() + INTERVAL '6 days', 260, 260, 34.90, 0),
  ('00000000-0000-0000-0000-000000000007', 'Zurich', 'Milan',     NOW() + INTERVAL '7 days', 120, 120, 42.00, 0);

INSERT INTO reservations (id, order_id, route_id, seats, status, created_at)
SELECT md5('seed-res-' || i)::uuid,
       md5('seed-order-' || i)::uuid,
       ('00000000-0000-0000-0000-' || lpad((2 + (i % 6))::text, 12, '0'))::uuid,
       1 + (i % 3),
       'RESERVED',
       NOW() - (i || ' hours')::interval
FROM generate_series(1, 40) AS i;

-- keep invariant I2: total - available = SUM(reserved seats)
UPDATE routes r
SET available_seats = r.total_seats - COALESCE(
      (SELECT SUM(res.seats) FROM reservations res
       WHERE res.route_id = r.id AND res.status = 'RESERVED'), 0);
COMMIT;
SQL

  echo "-- ordersdb: 40 CONFIRMED orders"
  sql eurotransit-orders-db ordersdb <<'SQL'
INSERT INTO orders (id, status, created_at, updated_at)
SELECT md5('seed-order-' || i)::uuid,
       'CONFIRMED',
       NOW() - (i || ' hours')::interval,
       NOW() - (i || ' hours')::interval
FROM generate_series(1, 40) AS i;
SQL

  echo "-- paymentsdb: 40 payment intents (one per order)"
  sql eurotransit-payments-db paymentsdb <<'SQL'
INSERT INTO payment_intents (id, order_id, amount, currency, status, idempotency_key, created_at, updated_at)
SELECT md5('seed-pay-' || i)::uuid,
       md5('seed-order-' || i)::uuid,
       (1 + (i % 3)) * 39.90,
       'EUR',
       'AUTHORIZED',
       'seed-' || md5('seed-order-' || i),
       NOW() - (i || ' hours')::interval,
       NOW() - (i || ' hours')::interval
FROM generate_series(1, 40) AS i;
SQL

  echo "-- notificationsdb: 40 SENT notifications"
  sql eurotransit-notifications-db notificationsdb <<'SQL'
INSERT INTO sent_notifications (order_id, status, created_at, updated_at)
SELECT md5('seed-order-' || i)::uuid::text,
       'SENT',
       NOW() - (i || ' hours')::interval,
       NOW() - (i || ' hours')::interval
FROM generate_series(1, 40) AS i;
SQL
}

status() {
  echo "== inventorydb =="
  sql eurotransit-inventory-db inventorydb <<'SQL'
SELECT id, origin, destination, total_seats, available_seats,
       total_seats - available_seats AS sold
FROM routes ORDER BY id;
SELECT status, COUNT(*) FROM reservations GROUP BY status;
SELECT COUNT(*) AS processed_events FROM processed_events;
SQL
  echo "== ordersdb =="
  sql eurotransit-orders-db ordersdb <<'SQL'
SELECT status, COUNT(*) FROM orders GROUP BY status ORDER BY status;
SELECT COUNT(*) AS non_terminal
FROM orders WHERE status NOT IN ('CONFIRMED', 'FAILED');
SQL
  echo "== paymentsdb =="
  sql eurotransit-payments-db paymentsdb <<'SQL'
SELECT status, COUNT(*) FROM payment_intents GROUP BY status;
SELECT COUNT(*) AS orders_with_multiple_intents FROM (
  SELECT order_id FROM payment_intents GROUP BY order_id HAVING COUNT(*) > 1
) d;
SQL
  echo "== notificationsdb =="
  sql eurotransit-notifications-db notificationsdb <<'SQL'
SELECT status, COUNT(*) FROM sent_notifications GROUP BY status;
SQL
}

k6_hint() { # k6_hint <route_id> <script>
  echo
  echo "Ready. Suggested load (app repo):"
  echo "  BASE_URL=https://<gateway> ROUTE_ID=$1 VUS=12 DURATION=10m k6 run tests/k6/$2"
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario="${1:-}"
case "$scenario" in
  status)
    status
    ;;
  clean)
    confirm
    wipe_all 100 2
    echo "Done: pristine state, migration-seed routes restored."
    ;;
  normal)
    confirm
    wipe_all 100 2
    seed_history
    echo "Done: normal state — 8 routes, 40 CONFIRMED orders consistent across all DBs."
    ;;
  ce-1|ce-3|ce-4|ce-5)
    confirm
    wipe_all "${SEATS:-5000}" 2
    echo "Done: ${scenario} state — route ...0001 at ${SEATS:-5000} seats, everything else pristine."
    k6_hint "$BIG_ROUTE" baseline.js
    ;;
  ce-2)
    confirm
    wipe_all 100 "${SEATS:-2}"
    echo "Done: ce-2 state — contention route ...00ce at ${SEATS:-2} seats."
    k6_hint "$TINY_ROUTE" ce2-contention.js
    ;;
  *)
    usage
    ;;
esac
