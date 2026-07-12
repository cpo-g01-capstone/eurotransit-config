# ADR 0024 — Dedicated CloudNativePG cluster for Notifications

- **Status:** Proposed
- **Date:** 2026-07-11
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** database, cloudnative-pg, notifications, gitops, idempotency
- **Supersedes / Superseded by:** —

---

## Context

The originating decision is **app-repo ADR-002 (Accepted)** — *"Notifications
deduplication via a dedicated PostgreSQL store."* Notifications consumes
`order-confirmed` with **at-least-once** delivery; without a durable dedup record the
same event, redelivered on rebalance or pod restart, produces duplicate confirmation
emails. ADR-002 gives Notifications its own PostgreSQL database with a `sent_notifications`
table keyed by the idempotency key, satisfying the `CLAUDE.md` requirement for dedup "at the
Kafka consumer level **and** at the database level." That is a **domain / consistency
decision owned by the data owner** — this ADR does not relitigate it; it records how the
**config repo delivers** it.

Two things forced a config-repo record:

1. **`CLAUDE.md` and the naming reference previously said only Orders uses PostgreSQL.**
   ADR-002 makes that stale — Notifications is no longer stateless. The delivery docs and
   the `postgres/` layer had to catch up or a future reader would treat the notifications DB
   as unexplained drift.

2. **`notifications-service` crashlooped on AKS** (`Connection to localhost:5432 refused`)
   because the chart injected no DB configuration and the app fell back to its localhost
   default — the same env-var-contract class of bug as orders (see **agent-log Case 13**).
   Fixing it requires both a database to exist and the correct env wiring.

`eurotransit-app`'s `notifications-service/application.yml` reads **service-prefixed** env
vars, R2DBC at runtime plus a separate JDBC URL for Flyway (Flyway is JDBC-only):

```yaml
spring.r2dbc.url:  ${NOTIFICATIONS_DB_R2DBC_URL:r2dbc:postgresql://localhost:5432/notificationsdb}
spring.flyway.url: ${NOTIFICATIONS_DB_JDBC_URL:jdbc:postgresql://localhost:5432/notificationsdb}
```

## Decision

Give Notifications its **own CloudNativePG cluster**, mirroring the Orders pattern rather
than sharing `eurotransit-orders-db`:

- **`postgres/eurotransit-notifications-db.yaml`** — CNPG `Cluster` (database
  `notificationsdb`, owner `app`, 1 instance for dev). Picked up by the existing
  `apps/data-infrastructure.yaml` Argo Application (`path: postgres`) — **no new Argo app**.
- **`values.yaml`** — a `notifications.db` section (rw host, port, name, operator secret
  `eurotransit-notifications-db-app`), identical shape to `orders.db`.
- **`templates/notifications/deployment.yaml`** — emit `NOTIFICATIONS_DB_R2DBC_URL`,
  `NOTIFICATIONS_DB_JDBC_URL`, `NOTIFICATIONS_DB_USERNAME`, `NOTIFICATIONS_DB_PASSWORD`;
  URLs built from `.Values.notifications.db.{host,port,name}`, credentials via
  `secretKeyRef` on the CloudNativePG-generated app secret. **Never** `SPRING_DATASOURCE_*`.

Naming follows `CLAUDE.md`: cluster `eurotransit-notifications-db`, services
`eurotransit-notifications-db-rw` / `-ro`, secret `eurotransit-notifications-db-app`.

## Alternatives considered

- **Share the Orders cluster (`ordersdb`) with a second database / schema (rejected).**
  Cheaper (one cluster), but couples two money-path services into one failure domain: a
  CloudNativePG primary failover (chaos experiment CE-5) would hit Orders and Notifications
  simultaneously, and the two blast radii could not be told apart. Per-service ownership
  keeps the failure-isolation story clean, which is the point of the capstone.
- **Keep Notifications stateless; dedup in memory or Redis (rejected upstream by ADR-002).**
  In-memory forgets on restart (fails DB-level dedup); Redis adds a component outside the
  approved Postgres-only stack.
- **Leave the chart injecting `SPRING_DATASOURCE_*` (rejected).** The app never reads those
  keys — it is an inert manifest that silently falls back to localhost. This is exactly the
  agent-log Case 13 failure mode.

## Consequences

**Easier / better:**
- Notifications gets a restart-safe dedup store; the `sent_notifications` invariant holds
  across pod death, rebalance, and redelivery — demonstrable under Kafka-partition / pod-kill
  chaos.
- Independent failover domain from Orders; CE-5 can isolate per-service impact.
- Delivery docs, naming table, and the env-var contract now match reality (Orders +
  Notifications each own a cluster); future chart edits have a canonical pattern to copy.

**Harder / risks:**
- **Second stateful workload to run and back up.** One more CNPG cluster, PVC, and app
  secret on a small dev cluster (single instance, 1Gi — modest). Revisit `instances: 3`
  before CE-5 / production HA, same as Orders.
- **End-to-end success depends on the app image shipping the Flyway migration**
  (`V1__init_notifications_schema.sql`). If the migration is absent from the built image,
  the pod will start but the dedup table won't exist — verify post-merge.
- **Does not address Inventory.** Inventory's datasource config is unwritten app-side and
  has no ADR yet; tracked separately.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] Data owner confirms the **own-cluster** choice over a shared/second-database on
      `eurotransit-orders-db` (this is the delivery reading of ADR-002).
- [ ] `helm template` renders the four `NOTIFICATIONS_DB_*` env vars pointing at
      `eurotransit-notifications-db-rw...:5432/notificationsdb`; no `SPRING_DATASOURCE_*`.
- [ ] After merge, `apps/data-infrastructure` stays Synced/Healthy and
      `kubectl get cluster -n eurotransit` shows `eurotransit-notifications-db` Ready, with
      secret `eurotransit-notifications-db-app` generated.
- [ ] `eurotransit-notifications` pod reaches Ready; logs show Flyway applying
      `V1__init_notifications_schema.sql` against `notificationsdb` (not localhost).
- [ ] Confirm the app image actually contains the migration.

## References

- **eurotransit-app** `docs/adr/ADR-002-notifications-dedup-store.md` — originating decision (Accepted)
- [ADR 0008 — Single Helm Chart for All Five Services](0008-single-helm-chart.md)
- `docs/agent-log.md` Case 11 — `SPRING_DATASOURCE_*` vs `<SVC>_DB_*` env-var-contract bug
- `postgres/eurotransit-orders-db.yaml` — the mirrored Orders cluster
- `apps/data-infrastructure.yaml` — Argo Application syncing `postgres/`
