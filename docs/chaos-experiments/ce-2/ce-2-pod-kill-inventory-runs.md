# CE-2 / Runs 1–2 — Pod kill on Inventory (2026-07-12)

*Execution record for [`ce-2-pod-kill-inventory.md`](ce-2-pod-kill-inventory.md). Two runs
the same afternoon: **run 1** killed the pod just after the seats sold out (crash while the
consumer drained the sold-out backlog); **run 2** killed it with seats still available and
reservations actively in flight — the literal "mid-reservation" the hypothesis names. Both
PASS. Run 2 is the authoritative one.*

## Setup (both runs)

| | |
|---|---|
| Date / operator | 2026-07-12 / @giova95 (Claude driving harness + kubectl, per session authorization; ADR 0019 gate on this record) |
| Injection | `PodChaos` `action: pod-kill`, `mode: one`, `gracePeriod: 0` (SIGKILL) on one `eurotransit-inventory` pod — [`ce-2-pod-kill-inventory.yaml`](ce-2-pod-kill-inventory.yaml) |
| Load | k6 `baseline.js`, 12 VUs, 4 m, on the 2-seat test route reseeded per run (operator seed, not a migration) |
| Target route | `…0000ce`, reseeded to the run's capacity before injecting |
| Money-path invariants | I1 `0 ≤ available ≤ total`; I2 `total − available = Σ reserved`; I3 no duplicate `(order_id, route_id)` |

*A pod-kill **replaces** the pod (a new pod is scheduled), it does not restart the
container in place — so `restartCount` stays 0 and the evidence is the `Killing` event plus
the new pod name/age. That is the correct signature of a crash, and what Chaos Mesh's
`pod-kill` and a real node/OOM event both produce.*

---

## Run 1 — kill just after sell-out (backlog drain under crash)

Route reseeded to **100 seats**. T0_kill **16:45:39 UTC**. By the kill the 100 seats had
already sold (available = 0 at 16:45:38, ~22 s into the load); the SIGKILL therefore caught
the inventory consumer **draining the sold-out backlog** — every remaining `order-placed`
had to be marked sold-out. This still exercises the core property: a crash + at-least-once
redelivery of `order-placed` while the consumer is actively processing.

- Pod `…-2xkqr` killed; replacement `…-nfhnv` scheduled and **Ready within ~30 s**;
  inventory consumer lag drained back to 0.
- k6: 2124 orders, **0 failed of 6803 requests, 0 × 429**, client p95 227 ms.
- **After convergence:** available = 0, **exactly 100 reservations** (`RESERVED`), I1/I2/I3
  all hold, **0 duplicate `(order_id, route_id)`**, **0 orders stuck** (100 CONFIRMED +
  2024 FAILED sold-out, all terminal), **0 duplicate payment intents**.

*Finding (timing, not a defect):* 100 seats sold in ~22 s, so the kill landed a beat after
the last-seat contention rather than inside it. Everything the hypothesis asserts held, but
to hit the literal "reservations in flight" case we raised capacity and re-ran — run 2.

---

## Run 2 — kill mid-reservation (authoritative)

Route reseeded to **500 seats** for a longer contention window. T0_kill **16:51:39 UTC**,
injected with **272 seats still available** — i.e. 228 already reserved and more actively
being reserved: `available` was observed falling **500 → 272 → 219 across the crash**, so
the SIGKILL demonstrably hit the consumer while reservations were in flight.

- Pod `…-4csdt` killed; replacement `…-pd67s` scheduled and Ready quickly; the surviving
  pod kept reserving through the kill (`available` never stalled at a wrong value, never
  went negative).
- k6: 2152 orders, **0 failed of 6890 requests, 0 × 429**.
- Checkout during the kill window (RED dashboard): **success 100 %, 0 × 5xx, p95 22.2 ms,
  the Payments breaker CLOSED throughout** — the synchronous money-path entry absorbed the
  inventory-consumer crash with no user-visible impact (we killed the *inventory* consumer,
  not a synchronous dependency; the sync path degrades only if Payments does).

### Verification (after convergence)

| Check | Result |
|---|---|
| **I1** — `available` never negative | ✅ `available = 0`, `0 ≤ 0 ≤ 500` |
| **No oversell** — reservations ≤ capacity | ✅ **exactly 500** `RESERVED`, never > 500 through the crash |
| **I2** — seats reconcile | ✅ `500 − 0 = Σ reserved (500)` |
| **I3** — no duplicate reservation | ✅ 0 duplicate `(order_id, route_id)` |
| **No lost/stuck order** | ✅ every cohort order terminal (0 DRAFT/RESERVED after convergence) |
| **Cross-DB coherence** | ✅ all **500 reservations map to 500 CONFIRMED orders** (join); 0 orphan reservations, 0 reservations on a non-confirmed order |
| **No double charge** | ✅ 0 orders with > 1 `payment_intent` |

*A note on how this was verified, for honesty: a first cohort query (`orders` filtered by
`created_at`) showed 488 CONFIRMED against 500 reservations — an alarming 12-order gap. It
was an artefact of the timestamp boundary (12 confirmed orders created a beat before the
cutoff), not a seat leak: joining the 500 `RESERVED` reservations back to `orders` returned
**500 CONFIRMED, 0 missing, 0 non-confirmed**. The authoritative check is the join across
the two databases, not a time-windowed count on one.*

## Outcome

| Run | Route cap | T0_kill (UTC) | Seats free at kill | Recovery | I1/I2/I3 | Oversell | Dup reservation | Lost/stuck | Double charge | Outcome |
|-----|-----------|---------------|--------------------|----------|----------|----------|-----------------|------------|---------------|---------|
| 1 | 100 | 16:45:39 | 0 (backlog drain) | new pod Ready ~30 s, lag→0 | ✅ | none (100/100) | 0 | 0 | 0 | **PASS** |
| 2 | 500 | 16:51:39 | **272 (in flight)** | new pod Ready fast, lag→0 | ✅ | **none (500/500)** | 0 | 0 | 0 | **PASS (authoritative)** |

## Conclusion

> **Draft — pending team ratification (ADR 0019).**

The hypothesis held. A SIGKILL of an inventory pod **with reservations in flight** (run 2,
272 seats free at the kill) caused **no oversell** (exactly 500 of 500 seats, `available`
never negative), **no duplicate reservation** (I3 = 0), **no lost order** (every order
terminal, cross-DB join clean), and **no double charge** — because the reservation is an
atomic conditional `UPDATE` under a row lock (only one caller wins a seat, CP) and every
consumer is idempotent (`processed_events` dedup committed **in the same transaction** as
the reservation, plus `UNIQUE(order_id, route_id)`), so the at-least-once redelivery of
`order-placed` after the crash re-ran as a safe no-op on already-processed work. The
synchronous checkout entry stayed at 100 % success / 0 × 5xx throughout: killing the
async consumer consumed **no** checkout error budget. Run 1 additionally shows the same
guarantees hold when the crash hits the sold-out backlog drain rather than live
contention.
