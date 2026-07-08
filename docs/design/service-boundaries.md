# Service boundaries and interaction map

*Owner: @Lollegro*

> **DRAFT — starter contributed by @giova95 to save time.** Not final: the owner reviews,
> corrects, and takes ownership. Ratified consistency decisions live in `consistency.md` (EM-24).
> Delete this banner once adopted.

## Guiding rule (sync vs async)

A boundary is **synchronous** only when a decision must be made *now* and the caller cannot
proceed without the answer (reserve a seat, authorize a payment). Everything else is
**asynchronous**, to decouple services, absorb load spikes, and avoid holding threads blocked
during I/O waits (blocking-vs-suspending model, async lecture).

## Services

| Service | Sync boundaries | Async boundaries (Kafka) | Consistency requirement |
|---------|-----------------|--------------------------|-------------------------|
| **Catalog** | `GET /catalog`, `GET /catalog/{id}` | consumes `inventory-reserved` for cached availability (best-effort) | Tolerant of staleness — **AP / EL** |
| **Orders** | `POST /orders` (entry, returns fast); orchestrates the pipeline | produces `order-placed`; consumes `payment-authorized` → `order-confirmed`, `notification-requested` | Strong on its own state (owns `eurotransit-orders-db`). A **failure domain**. |
| **Inventory** | reservation decision (contended resource) | produces `inventory-reserved`; consumes compensation to release seats | **CP / EC** — see `consistency.md` |
| **Payments** | authorize (decision now) | produces `payment-authorized` | **Strict idempotency** — see `idempotency.md` |
| **Notifications** | — (no public API) | consumes `notification-requested` | **None** — may fail entirely (graceful degradation) |

> ⚠️ **Point to reconcile with the team.** The assignment describes `Orders → Inventory` and
> `Orders → Payments` as **synchronous** calls ("where a decision must be made *now*"). The current
> EM-23/EM-20 implementation performs the reservation through the **Kafka** pipeline (consumer-driven)
> rather than a synchronous HTTP call. Decide and document which boundary we actually use — and be
> ready to justify it at the oral. Both are defensible, but the doc and the code must agree.

## Money path trace (checkout)

Order state machine (from the Orders schema): `DRAFT → RESERVED → PAID → CONFIRMED` (or `FAILED`).

1. `client → gateway (Traefik) → POST /orders`.
2. Orders generates an `orderId` (UUID), writes the order as `DRAFT`, publishes `order-placed`,
   returns quickly to the client. *(Decoupling → reduces cost/scaling pressure, not latency.)*
3. Reservation stage → Inventory reserves seats atomically → order `RESERVED`, `inventory-reserved`.
4. Payment stage → Payments authorizes (idempotent) → order `PAID`, `payment-authorized`.
5. Confirmation → `order-confirmed`, order `CONFIRMED`, `notification-requested`.
6. Notifications sends the confirmation. If it is down, the order stays `CONFIRMED` → **checkout still succeeds**.

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
- [ ] Confirm the sync vs Kafka-driven reservation boundary (see the ⚠️ note above) and align code/doc.
- [ ] Confirm Catalog's availability-refresh strategy (event-driven vs timer).
