# Consistency model — Inventory

*Owner: @MauroC0l · EM-24 analysis drafted by @giova95*

> **Team-authored design decision.** The consistency-model choice and its CAP/PACELC
> justification are judgments the team owns and must defend at the oral. This is a draft to
> review, not an agent decision.

## CAP / PACELC analysis

Inventory is the one place where **correctness genuinely conflicts with availability**: two
customers must never buy the last seat.

**Choice: CP (in CAP), PC/EC (in PACELC).**

- **CAP → CP** (Consistency + Partition-tolerance; sacrifice Availability). Overselling is a
  correctness error we consider unacceptable. During a network partition we **reject** the
  reservation (temporary unavailability → HTTP 503) rather than risk a double-sell.
- **PACELC → PC/EC.** In a **P**artition we choose **C** (reject). In the **E**lse case (no
  partition) we still choose **C** over **L**atency: reservation reads/writes always go to the
  Inventory **primary** (`eurotransit-inventory-db-rw`), never to a potentially stale
  read replica, accepting slightly higher latency for correctness.

**Contrast with Catalog (deliberate, different model for different data).**

| Service | CAP | PACELC | Why |
|---------|-----|--------|-----|
| **Catalog** | AP | EL | An offer list may be slightly stale; favour availability + low latency (may read a replica/cache). |
| **Inventory** | CP | EC | A seat is a finite, contended resource; correctness always wins over availability, always read/write the primary. |

## Implementation

**Ratified:** Inventory owns a dedicated CloudNativePG cluster (`eurotransit-inventory-db`), and
reservation uses the atomic conditional `UPDATE` below (not the state-machine variant, for now).

Atomic **conditional reservation** in PostgreSQL (single-primary, CloudNativePG):

```sql
UPDATE inventory
   SET reserved = reserved + :qty
 WHERE product_id = :id
   AND (capacity - reserved) >= :qty;   -- the row is updated ONLY if seats remain
```

- If `rowsAffected == 0` → seats exhausted → return **HTTP 409 Conflict**.
- The atomicity of the single `UPDATE` plus `READ COMMITTED` isolation guarantees that two
  concurrent transactions cannot both exceed capacity: **no oversell, no application-level lock**.
  The database is the single arbiter of the contended resource.
- Reservation carries the `orderId` and is protected by `UNIQUE(order_id)` so that a retried or
  duplicated `order-placed` event does not double-reserve (see `idempotency.md`).

*Optional enhancement (higher ceiling):* a reservation **state machine**
`RESERVED → CONFIRMED → RELEASED` with a TTL and a compensating `release` on cancellation/timeout.
This adds richness (and a reconciliation story) at the cost of complexity. Decide as a team.

## What we sacrifice in a partition

- If the Inventory PostgreSQL primary is unreachable (network partition, or during a CloudNativePG
  primary failover), reservations **fail fast** (HTTP 503 / the caller's circuit breaker opens)
  until a new primary is elected. We deliberately accept **temporary checkout unavailability**
  rather than an oversell.
- Recovery target: the system must recover within our stated **RTO** (measured in chaos experiment
  #5, "CloudNativePG primary failover"). Record the observed RTO there.

## Open decisions for the team to confirm

- [x] **Inventory persistence.** RATIFIED: Inventory owns a dedicated CloudNativePG cluster
      (`eurotransit-inventory-db`) so each service owns its data.
- [x] **Reservation implementation.** RATIFIED: simple atomic conditional `UPDATE` (state machine
      deferred as a possible later enhancement).
- [ ] Isolation level: `READ COMMITTED` is sufficient for the conditional `UPDATE`; confirm no read
      path relies on stronger guarantees.
