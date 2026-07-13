# CE-2 — Manual pre-test: Pod kill on Inventory mid-reservation

*Task: EM-29. This is the **manual dry-run** that precedes the automated Chaos Mesh
experiment CE-2. Owner: (unassigned — picked up for M2).*

> **Why a manual pre-test first?** Following the scientific method from the resilience lecture:
> we validate the invariant *by hand*, cheaply, in a non-prod cluster, before automating it. This
> confirms (a) the invariant actually holds, and (b) our dashboards/queries surface what we need to
> observe. *"Resilience that has never been tested is a hypothesis, not a property."* Start small,
> in staging, with a defined abort condition.

## Scope and references

- Corresponds to **chaos experiment #2** in the capstone spec: *"Pod kill on Inventory
  mid-reservation: does idempotency plus the reservation model prevent oversell or double-charge?"*
- Consistency model: [`../design/consistency.md`](../design/consistency.md) — Inventory is **CP / PC-EC**.
- Idempotency scheme: [`../design/idempotency.md`](../design/idempotency.md).
- Inventory implementation under test (EM-23): reservation is an **atomic conditional `UPDATE`**
  (`available_seats >= :seats AND version = :version`) with **optimistic locking + bounded retry**;
  idempotency comes from `UNIQUE(order_id, route_id)`, an application-level existence check, and a
  `processed_events` dedup row committed **in the same transaction** as the reservation.

## Preconditions

- The money path is deployed to a **dev/staging** cluster. **Never run this against production.**
- Access to `kubectl` for the `eurotransit` namespace and to the Inventory database
  (`eurotransit-inventory-db`) via `psql` (port-forward the `-rw` service).
- A driver to generate load on the money path: `POST /orders` through the Traefik gateway
  (preferred, end-to-end) or direct publication of `order-placed` events to Kafka.
- A test route seeded with **tiny capacity** so oversell is easy to trigger. Example seed:

  ```sql
  INSERT INTO routes (id, origin, destination, departure_time, total_seats, available_seats, price, version)
  VALUES ('00000000-0000-0000-0000-0000000000ce', 'Turin', 'Milan', NOW() + INTERVAL '1 day', 2, 2, 19.90, 0);
  ```

## Steady state (define "normal" before injecting)

Capture a baseline first. Steady state = all of:

- **SLI:** reservations succeed under normal load (checkout success-rate within SLO).
- **Invariant I1 (no oversell):** for every route, `0 <= available_seats <= total_seats`.
- **Invariant I2 (seats reconcile):** `total_seats - available_seats == SUM(reservations.seats)` for that route.
- **Invariant I3 (no duplicate reservation):** at most one reservation per `(order_id, route_id)`.

## Hypothesis

Killing the Inventory Pod while it is processing reservations — and the resulting **at-least-once
Kafka redelivery** of `order-placed`, even under contention on the last seats — will **NOT**:

1. **oversell** (`available_seats` never goes negative; no route sells more than `total_seats`), nor
2. **create duplicate reservations** for the same order,

because the reservation is an **atomic conditional `UPDATE`** (only one caller can win the last
seat, CP) and is **idempotent** (`UNIQUE(order_id, route_id)` + app check + `processed_events` dedup
in the same transaction). In-flight work either commits or is cleanly retried after restart.

## Method (manual procedure)

### Variant A — Contention only (control, no failure injected)

1. Reset the test route to `available_seats = 2`.
2. Fire **5 concurrent** `POST /orders`, each for **1 seat** on the test route.
3. **Expect:** exactly **2** succeed (reserved), **3** are rejected (sold out /
   `InsufficientSeatsException`).
4. Run the verification queries below → I1–I3 must hold. This proves the atomic reservation works
   before we add chaos.

### Variant B — Pod kill mid-reservation (the experiment)

1. Reset the test route to `available_seats = 2`.
2. Start a **sustained concurrent load** of orders for the test route (more orders than capacity),
   so reservations are actively in flight.
3. While load is in flight, identify the Inventory Pod consuming messages and kill it **once**:
   ```bash
   kubectl -n eurotransit get pods -l app.kubernetes.io/name=eurotransit-inventory
   kubectl -n eurotransit delete pod <inventory-pod>
   ```
   *(In the automated CE-2 this becomes a Chaos Mesh `PodChaos` one-shot `pod-kill`.)*
4. Let the Pod restart. Kafka redelivers any `order-placed` whose offset was not committed.
5. Stop the load; wait for the pipeline to **drain and converge**.
6. Run the verification queries → I1–I3 must hold, **and** every order must reach a terminal state
   (no order stuck `PENDING`/mid-flight).

### Variant C — Duplicate-message variant

- Re-emit the **same** `order-placed` event twice (same key/`orderId`). **Expect:** one reservation,
  one decrement (guarded by `processed_events` and `UNIQUE(order_id, route_id)`).

## Observation — verification queries (run against `eurotransit-inventory-db`)

```sql
-- I1: no negative, no over-capacity
SELECT id, total_seats, available_seats
FROM routes WHERE id = '00000000-0000-0000-0000-0000000000ce';

-- I2: seats reconcile (reserved_sum must equal expected_reserved)
SELECT r.total_seats,
       r.available_seats,
       COALESCE(SUM(res.seats), 0)        AS reserved_sum,
       r.total_seats - r.available_seats  AS expected_reserved
FROM routes r
LEFT JOIN reservations res ON res.route_id = r.id
WHERE r.id = '00000000-0000-0000-0000-0000000000ce'
GROUP BY r.id, r.total_seats, r.available_seats;

-- I3: no duplicate reservation for the same (order, route) — must return ZERO rows
SELECT order_id, route_id, COUNT(*)
FROM reservations
GROUP BY order_id, route_id
HAVING COUNT(*) > 1;
```

Also watch, during the run:
- **Inventory RED dashboard** (rate/errors/duration) and **Pod restarts** metric.
- **Kafka consumer lag** for the inventory consumer (should spike on kill, then drain to ~0).
- **Cross-check (double-charge, Payments / EM-25):** verify at most **one** payment authorization per
  order. Out of the primary scope of this inventory pre-test, but note the result — it is the other
  half of the CE-2 question and depends on the payment idempotency key (`orderId`).

## Pass / fail criteria

- **PASS** if, after the run: **I1** holds (`available_seats >= 0`, sold `<= total_seats`), **I2**
  reconciles (`reserved_sum == expected_reserved`), **I3** returns zero rows, and the pipeline
  **converged** (no orphaned/stuck orders).
- **FAIL** if `available_seats < 0`, sold `> total_seats`, any duplicate reservation appears, an order
  is lost/stuck, or I2 does not reconcile.

## Abort / safety

Dev/staging only. To abort: stop the load generator, scale Inventory back to its desired replica
count, and reset the test route seats via SQL. Do not run against production.

## Results (fill in during the run)

| Date | Operator | Variant | Orders fired | Reserved | Rejected | available_seats after | reserved_sum | Duplicates (I3) | Converged? | Outcome | Notes |
|------|----------|---------|--------------|----------|----------|-----------------------|--------------|-----------------|------------|---------|-------|
|      |          | A       |              |          |          |                       |              |                 |            |         |       |
|      |          | B       |              |          |          |                       |              |                 |            |         |       |
|      |          | C       |              |          |          |                       |              |                 |            |         |       |

## Next step

Once this manual pre-test **PASSES**, automate it as **CE-2** with a Chaos Mesh `PodChaos`
(`pod-kill`) and record the full experiment — hypothesis, steady state, observations from our own
dashboards, whether the hypothesis held, and any changes made — in
`docs/chaos-experiments/ce-2-pod-kill-inventory.md`.
