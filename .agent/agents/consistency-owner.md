# Agent: Data & Consistency Owner — CloudNativePG, Inventory, Idempotency

## Scope

Primary ownership of:
- **CloudNativePG configurations**: cluster setups, pooling, backup/recovery settings.
- **PostgreSQL schemas and migrations**: managing database evolution for `Orders` and `Inventory`.
- **Inventory Consistency Model**: implementation of reservations respecting CAP/PACELC trade-offs (favoring consistency).
- **Idempotency mechanisms**: ensuring the money path (Payments, Orders) is safe contro retry and duplicated events.

Cross-cutting awareness:
- Async processing pipeline (must ensure consumers process messages idempotently).
- Chaos experiments (CE-2 Pod kill on Inventory mid-reservation, CE-5 CloudNativePG primary failover).

---

## Decisions made

### Database Engine
**Decision:** PostgreSQL managed by CloudNativePG operator.
**Rationale:** Required by the project PDF (Lab03). Provides high availability, streaming replication, and automated failover natively in Kubernetes.

### Inventory Reservation Consistency
**Decision:** Optimistic locking or atomic SQL updates.
**Rationale:** We must NEVER oversell a seat. In case of a network partition (CAP), we sacrifice Availability for Consistency (CP). 

### Idempotency
**Decision:** Strict idempotency across the critical path using Idempotency Keys.
**Rationale:** Retried payment authorizations or duplicated Kafka `order-placed` events must not double-charge or double-reserve. Idempotency keys must be persisted transactionally.

---

## Constraints and invariants

**Do NOT change without discussing with me:**

1. **The "Never Oversell" Invariant:** No change to the Inventory service can compromise the atomic nature of seat reservations.
2. **Idempotency is mandatory:** No payment or reservation endpoint/consumer can be introduced without explicit idempotency key validation.
3. **Database migrations:** Schema changes must be done via explicit versioned migrations (e.g. Flyway/Liquibase). No manual `ALTER TABLE` in production or auto-ddl from ORMs.
4. **CloudNativePG Replica/Failover settings:** These directly impact the CE-5 chaos experiment RTO. Do not alter `instances` count or `postgresql` configurations without review.
5. **Transactions:** Keep transaction boundaries small to avoid locking contention on the inventory table under high load.

---

## How to contribute to my area

### Modifying Database Schemas
- Provide the migration script (e.g., `V1__init.sql`) in the PR.
- Ensure migrations are backward compatible if doing blue/green deployments.

### Touching the Async Pipeline
- When writing a Kafka consumer, wrap the processing logic in an idempotency check.
- If processing fails mid-way, ensure the state can be safely retried without side effects.

### Review checklist for PRs touching my area
- [ ] Database migrations are present and tested.
- [ ] Endpoints/Consumers that modify state use an idempotency key.
- [ ] No `GlobalScope` or blocking calls inside coroutines interacting with the DB (use `Dispatchers.IO` or R2DBC).
- [ ] CloudNativePG configurations align with our high availability requirements.

---

## Open questions

- **Idempotency Key Transport:** Do we use an HTTP Header (`Idempotency-Key`) for synchronous calls and a payload field for Kafka events?
- **Garbage Collection of Idempotency Records:** Strategy for cleaning up old idempotency keys to prevent unbounded database growth.
- **RTO Verification:** Exactly how long does a CloudNativePG failover take under our load, and does it meet our SLOs during the CE-5 experiment?

---

## Useful context for AI

When generating artifacts in this area, the following context is fixed and must not be changed:

### CloudNativePG Cluster (canonical form)
```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: eurotransit-db
  namespace: eurotransit
spec:
  instances: 3
  primaryUpdateStrategy: unsupervised
  storage:
    size: 1Gi
  bootstrap:
    initdb:
      database: orders
      owner: app
```

### Idempotency Pattern (Conceptual)
When generating Kotlin code for an idempotent operation:
1. Extract the `idempotencyKey` from the request/event.
2. Attempt to insert the key into an `idempotency_records` table (or similar construct).
3. If the insert fails due to a unique constraint violation, the request is a duplicate. Return the cached result or a standard acknowledgment without reprocessing.
4. If the insert succeeds, proceed with the business logic transactionally.

### Database Interaction Pattern
- **Stack:** Kotlin + Coroutines.
- **Rule:** Must be non-blocking. If using JDBC, wrap in `withContext(Dispatchers.IO)`. If using Spring Data R2DBC, use suspend functions directly.
- **Transactions:** Use `@Transactional` (Spring) o programmatic transactions carefully.

### Agent Mistakes
Any generated code that is unsafe, non-idempotent, o violates the consistency invariants must be logged in `docs/agent-log.md` with an explanation.
