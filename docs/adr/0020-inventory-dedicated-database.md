# ADR 0020 — Dedicated CloudNativePG cluster for Inventory

- **Status:** Proposed
- **Date:** 2026-07-11
- **Deciders:** _full team to ratify_
- **Context tags:** database, cloudnative-pg, inventory, gitops, seat-reservation
- **Supersedes / Superseded by:** —

---

## Context

Inventory-service owns the seat-reservation domain: it tracks routes with available seats,
creates reservations against orders, and uses a `processed_events` table for Kafka consumer
idempotency (at-least-once delivery). The app repo already declares the full persistence
stack:

- `build.gradle.kts`: `spring-boot-starter-data-r2dbc`, `flyway-core`,
  `flyway-database-postgresql`, `postgresql`, `r2dbc-postgresql`.
- `application.yml`: R2DBC + Flyway config reading **service-prefixed** env vars:
  ```yaml
  spring.r2dbc.url:  ${INVENTORY_DB_R2DBC_URL:r2dbc:postgresql://localhost:5432/inventorydb}
  spring.flyway.url: ${INVENTORY_DB_JDBC_URL:jdbc:postgresql://localhost:5432/inventorydb}
  ```
- `V1__init_inventory_schema.sql`: `routes`, `reservations`, `processed_events` tables.

The config repo already ships a CloudNativePG cluster manifest
(`postgres/eurotransit-inventory-db.yaml`), but the **Helm chart never wires the DB
credentials into the Deployment**. Without `INVENTORY_DB_*` env vars, the app falls back to
its `localhost` default and crashes with `Failed to determine a suitable R2DBC Connection
URL` — the same class of bug as notifications (ADR 0024, agent-log Case 13).

This ADR records the data-ownership decision and the delivery fix.

## Decision

Give Inventory its **own CloudNativePG cluster**, consistent with Orders and Notifications:

- **`postgres/eurotransit-inventory-db.yaml`** — CNPG `Cluster` (already exists; database
  `inventorydb`, owner `app`, 1 instance for dev). Synced by the existing
  `apps/data-infrastructure.yaml` Argo Application.
- **`values.yaml`** — add `inventory.db` section (rw host, port, name, operator secret
  `eurotransit-inventory-db-app`), identical shape to `orders.db` / `notifications.db`.
- **`templates/inventory/deployment.yaml`** — emit `INVENTORY_DB_R2DBC_URL`,
  `INVENTORY_DB_JDBC_URL`, `INVENTORY_DB_USERNAME`, `INVENTORY_DB_PASSWORD`; URLs built from
  `.Values.inventory.db.{host,port,name}`, credentials via `secretKeyRef` on the
  CloudNativePG-generated app secret. **Never** `SPRING_DATASOURCE_*`.

Naming follows fleet convention: cluster `eurotransit-inventory-db`, services
`eurotransit-inventory-db-rw` / `-ro`, secret `eurotransit-inventory-db-app`.

## Alternatives considered

- **Share the Orders cluster with a second database / schema (rejected).**
  Cheaper (one cluster), but couples two money-path services into one failure domain: a
  CloudNativePG primary failover would hit Orders and Inventory simultaneously. Per-service
  ownership keeps failure isolation clean — critical for chaos experiments (CE-2 pod-kill
  inventory already exists and must not cascade to Orders).
- **Reuse Notifications cluster (rejected).** No domain overlap; Notifications is a
  best-effort service — tying its failure domain to the contended inventory seat-lock path
  adds unjustified risk.

## Consequences

**Easier / better:**
- Inventory pods start successfully on AKS; the seat-reservation flow works end-to-end.
- Independent failure domain: CE-2 (pod-kill inventory) can be run without affecting
  Orders or Notifications databases.
- Fleet-wide consistency: all three stateful services (Orders, Inventory, Notifications)
  follow the same own-cluster pattern, making the chart predictable.

**Harder / risks:**
- **Third stateful workload.** One more CNPG cluster, PVC, and app secret. Modest for dev
  (single instance, 1Gi). Bump to `instances: 3` before production HA.
- **End-to-end success requires the app image to ship the Flyway migration.** If
  `V1__init_inventory_schema.sql` is absent from the built image, the pod starts but tables
  don't exist — verify post-merge.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] Data owner confirms the **own-cluster** choice.
- [ ] `helm template` renders the four `INVENTORY_DB_*` env vars pointing at
      `eurotransit-inventory-db-rw...:5432/inventorydb`; no `SPRING_DATASOURCE_*`.
- [ ] After merge, `apps/data-infrastructure` stays Synced/Healthy and
      `kubectl get cluster -n eurotransit` shows `eurotransit-inventory-db` Ready, with
      secret `eurotransit-inventory-db-app` generated.
- [ ] `eurotransit-inventory` pod reaches Ready; logs show Flyway applying
      `V1__init_inventory_schema.sql` against `inventorydb` (not localhost).

## References

- [ADR 0024 — Dedicated CloudNativePG cluster for Notifications](0024-notifications-dedicated-database.md) — mirrored pattern
- [ADR 0008 — Single Helm Chart for All Five Services](0008-single-helm-chart.md)
- `postgres/eurotransit-inventory-db.yaml` — the CNPG cluster manifest
- `postgres/eurotransit-orders-db.yaml` — the mirrored Orders cluster
- `docs/chaos-experiments/ce-2-pod-kill-inventory.md` — inventory chaos experiment
