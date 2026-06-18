# Agent: Mauro — Data & Consistency

## Scope
I am responsible for the **Data & Consistency** area of the EuroTransit Marketplace. My scope includes the CloudNativePG operator configurations, the PostgreSQL database schemas for `Orders` and `Inventory`, the consistency model for reservations (CAP/PACELC), and the idempotency logic (specifically for `Payments` and the overall money path).

## Decisions made
- **Database Engine:** PostgreSQL via CloudNativePG Operator for `Orders` and `Inventory` (project requirement).
- **Inventory Reservation:** We use optimistic locking or atomic SQL updates to ensure strict consistency. 
- **Idempotency:** Strict idempotency is enforced across the critical path. Duplicated `order-placed` or retried payment authorizations will not result in double-charges or double-reservations.
- **Consistency vs Availability:** For the Inventory, correctness over availability is prioritized during partitions (CP in CAP). The invariant is "never oversell".

## Constraints and invariants
- **Invariant:** The system must *never* oversell tickets. 
- **Data migrations:** Any change to the database schemas must be done via explicit versioned migrations (e.g., Flyway/Liquibase).
- **No missing idempotency:** No payment or reservation endpoint can be created without an explicit idempotency key validation.
- **Transactions:** The boundary of transactions must be kept small to avoid locking contention under high load.

## How to contribute to my area
- If you are opening a PR that modifies the database schema, ensure the migration scripts are included and tested.
- If you touch the asynchronous pipeline (Kafka consumers), ensure that processing the same message twice does not break the state.
- Coordinate with me before modifying CloudNativePG replica settings or failover configurations, as this directly impacts the CE-5 chaos experiment.

## Open questions
- The exact format and transport of the idempotency key (e.g., HTTP Header `Idempotency-Key` vs payload field).
- Strategy for garbage-collecting old idempotency records to prevent infinite database growth.
- Verification of the RTO (Recovery Time Objective) during the CloudNativePG primary failover (CE-5).

## Useful context for AI
- **Stack:** Kotlin + Spring Boot, Coroutines/Flows.
- **Infrastructure:** Kubernetes (k3d), Argo CD, Traefik, Strimzi (Kafka), CloudNativePG.
- **Idempotency implementation:** When generating code for consumers or endpoints, always include a check against an idempotency table or unique constraint. 
- **Database interactions:** Must be non-blocking. Use Spring Data R2DBC or wrap JDBC calls in appropriate IO coroutine dispatchers (`Dispatchers.IO`).
- **Agent mistakes:** Any generated code that is unsafe, non-idempotent, or violates the consistency invariants must be logged in `docs/agent-log.md` with an explanation.
