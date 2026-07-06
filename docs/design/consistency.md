# Consistency model — Inventory

*Owner: @MauroC0l*

## CAP / PACELC analysis

### CAP theorem

The inventory service chooses **CP** (Consistency over Availability):

- **Consistency:** The `available_seats` counter must be authoritative. If two customers
  race for the last seat, exactly one must succeed and the other must be rejected. An
  oversold seat is **unrecoverable** — it requires manual intervention, refunds, and
  damages customer trust.
- **Availability sacrifice:** Under a network partition between the application and
  PostgreSQL, the inventory service returns an error (HTTP 503 / Kafka NACK) rather than
  accepting a reservation it cannot validate. This is the correct trade-off for a
  financial transaction on the money path.

### PACELC framework

| Condition | Choice | Rationale |
|-----------|--------|-----------|
| **P** (partition) | **C** over A | Reject reservations rather than risk overselling |
| **E** (else / normal) | **C** over L | Accept slightly higher latency from optimistic lock retries rather than weaker consistency |

**Classification: PC/EC** — we always favour consistency, even at the cost of latency
(optimistic lock retries add ~1–5 ms per retry under contention) and availability
(partitioned clients get errors, not stale data).

## Implementation

### Strategy: Optimistic locking with atomic SQL

Two layers of protection guarantee the **"never oversell"** invariant:

#### Layer 1 — Atomic SQL WHERE clause

```sql
UPDATE routes
SET available_seats = available_seats - :seats,
    version = version + 1
WHERE id = :routeId
  AND available_seats >= :seats
  AND version = :expectedVersion
```

PostgreSQL executes this as a single statement with a **row-level lock**. Only one
concurrent UPDATE can succeed for the same row. The `available_seats >= :seats` guard
makes it physically impossible for `available_seats` to go negative — this is the
**database-level invariant**.

#### Layer 2 — Optimistic lock with bounded retry

The `version` column enables **optimistic concurrency control**:

1. **Read** the route to get `available_seats` and `version`
2. **Attempt** the atomic UPDATE with `WHERE version = :expectedVersion`
3. If `updated == 0` (version conflict — another transaction won the race):
   - **Re-read** the route
   - If `available_seats >= seats` → **retry** (up to 3 attempts)
   - If `available_seats < seats` → **reject** (`InsufficientSeatsException`)
4. If all retries exhausted → **reject** (`VersionConflictException`)

This retry loop handles the benign case where seats are still available after a conflict,
while the bounded retry (max 3) prevents unbounded spinning under extreme contention.

#### Alternative: Pure atomic decrement

For scenarios where only the "never oversell" invariant is needed (no broader optimistic
locking), a simpler method is available:

```sql
UPDATE routes
SET available_seats = available_seats - :seats
WHERE id = :routeId
  AND available_seats >= :seats
```

This relies solely on PostgreSQL's row-level locking and the WHERE guard. It does not
track versions but still guarantees two customers cannot buy the last seat.

### Idempotency at reservation level

Double-reservation is prevented at two levels:

1. **Application level:** `findByOrderIdAndRouteId(orderId, routeId)` — returns existing
   reservation if already processed
2. **Database level:** `UNIQUE INDEX idx_reservations_order_route ON reservations(order_id, route_id)`
   — constraint violation on duplicate insert

### Transaction boundaries

Per [consistency-owner.md](file:///c:/Users/Windows/Desktop/CPO/Project/eurotransit-config/.agent/agents/consistency-owner.md#L41):
transactions are kept small. The Kafka consumer wraps the reservation + dedup record
insert in a single transaction. The downstream Kafka publish (`inventory-reserved`)
happens **outside** the transaction — at-least-once delivery is safe because the
Payments consumer is also idempotent.

## What we sacrifice in a partition

| Scenario | Behaviour | Impact |
|----------|-----------|--------|
| PostgreSQL unreachable | Inventory returns error; Kafka consumer NACKs and redelivers | Reservations are temporarily unavailable; no data corruption |
| Kafka partition | Events queue up; on recovery, consumers process idempotently | Increased latency, no duplicates or loss |
| Pod kill mid-reservation (CE-2) | Transaction rolls back; Kafka redelivers; retry succeeds | Transient delay, no oversell |

**We sacrifice availability and latency. We never sacrifice consistency.**
