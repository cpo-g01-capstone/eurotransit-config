# Service boundaries and interaction map

*Owner: @Lollegro*

> Adopted by the owner; ratified consistency decisions live in `consistency.md` (EM-24).
> Event topology below matches the code on `main` (2026-07-12 doc-alignment pass).

## Guiding rule (sync vs async)

A boundary is **synchronous** only when a decision must be made *now* and the caller cannot
proceed without the answer (reserve a seat, authorize a payment). Everything else is
**asynchronous**, to decouple services, absorb load spikes, and avoid holding threads blocked
during I/O waits (blocking-vs-suspending model, async lecture).

## Services

| Service | Sync boundaries | Async boundaries (Kafka) | Consistency requirement |
|---------|-----------------|--------------------------|-------------------------|
| **Catalog** | `GET /catalog`, `GET /catalog/{id}` | consumes `inventory-reserved` for cached availability (best-effort) | Tolerant of staleness — **AP / EL** |
| **Orders** | `POST /orders` (entry, returns fast); orchestrates the pipeline; calls Payments authorize sync (ADR 0018) | produces `order-placed`, `order-confirmed`, `order-failed` (compensation trigger); consumes `inventory-reserved`, `payment-authorized`, `order-failed` (marks order FAILED) | Strong on its own state (owns `eurotransit-orders-db`). A **failure domain**. |
| **Inventory** | reservation decision (contended resource) | produces `inventory-reserved`, `order-failed` (sold-out); consumes `order-placed`, `order-failed` (releases reserved seats) | **CP / EC** — see `consistency.md` |
| **Payments** | authorize (decision now, sync HTTP from Orders — ADR 0018) | produces `payment-authorized` | **Strict idempotency** — see `idempotency.md` |
| **Notifications** | — (no public API) | consumes `order-confirmed` only (app ADR-001; `notification-requested` is reserved, not wired — agent-log Case 11); poison messages → `order-confirmed.DLT` | **None** — may fail entirely (graceful degradation) |

> ✅ **RESOLVED (team vote, 2026-07-11 — see ADR 0018).** The **payment authorization is a
> synchronous HTTP call** `Orders → Payments` (idempotent, wrapped in a Resilience4j circuit
> breaker + timeout + bulkhead, with a queued-retry fallback). The reservation and the rest of the
> pipeline stay Kafka-driven. Rationale: authorizing the customer's money is a decision needed
> *now* (the sync rule above); this also makes chaos experiment CE-1 demonstrable as specified.

## Money path trace (checkout)

Order state machine (from the Orders schema): `DRAFT → RESERVED → CONFIRMED` (or `FAILED`). (`PAID` removed: authorize is synchronous, ADR 0018.)

1. `client → gateway (Traefik) → POST /orders`.
2. Orders generates an `orderId` (UUID), writes the order as `DRAFT`, publishes `order-placed`,
   returns quickly to the client. *(Decoupling → reduces cost/scaling pressure, not latency.)*
3. Reservation stage → Inventory reserves seats atomically → order `RESERVED`, `inventory-reserved`.
4. Payment step → Orders calls Payments authorize synchronously (idempotent, breaker — ADR 0018) → `payment-authorized`.
5. Confirmation → `order-confirmed`, order `CONFIRMED`.
6. Notifications consumes `order-confirmed` (ADR-001) and sends the confirmation. If it is down,
   the order stays `CONFIRMED` → **checkout still succeeds**.
7. Compensation path: payment retries exhausted or sold-out → `order-failed` → Inventory releases
   the reserved seats, Orders marks the order `FAILED` (decision D4, 2026-07-11).

Every step is idempotent (Kafka is at-least-once; remote calls are retried). See `idempotency.md`.

## Async cost analysis (blocking vs suspending)

- **Where async reduces cost/scaling pressure:** the pipeline stages are **I/O-bound** (Postgres,
  downstream HTTP, Kafka). With suspending functions the thread is freed during the wait → fewer
  threads/memory per pod → fewer replicas/nodes → lower cost. The fast entry response is *decoupling*,
  not a latency win.
- **Where async would NOT help:** CPU-bound work (heavy serialization/crypto). Suspending does not add
  cores → scale with replicas instead. Dispatcher choice (`Dispatchers.IO` vs `Default`) is a
  resource-allocation decision, not a performance tweak.

## Open items for the owner
- [x] Sync vs Kafka boundary — RESOLVED by team vote / ADR 0018 (payment authorize sync; reservation stays Kafka-driven).
- [x] Confirm Catalog's availability-refresh strategy — RESOLVED: event-driven, an event-fed
      AP in-memory cache consuming `inventory-reserved` (app ADR 0006, implemented in app PR #17).
