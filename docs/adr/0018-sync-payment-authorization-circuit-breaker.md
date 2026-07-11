# ADR 0018 — Synchronous payment authorization with a circuit breaker (decision D1 = option A)

- **Status:** Accepted (team decision, 2026-07-11)
- **Date:** 2026-07-11
- **Deciders:** whole team (D1 in the decision agenda)
- **Related:** capstone spec Pillar C + chaos experiment #1; `docs/design/service-boundaries.md`;
  ADR 0017 (chaos execution model)

## Context

The capstone spec requires *"circuit breakers on cross-service **synchronous** calls
(Orders → Payments)"* and chaos experiment CE-1 is *"latency injection into Payments: does
the Orders circuit breaker open and the fallback engage, while Catalog browsing stays
healthy?"*. Our pipeline had drifted to fully Kafka-driven stages: with no synchronous
call there was no place for a breaker, and CE-1 was not demonstrable (flagged as decision
**D1**).

## Decision

**Option A.** The payment authorization becomes a **synchronous HTTP call**
`Orders → Payments` (`POST /payments/authorize`, idempotent via the `Idempotency-Key`
header, EM-25 scheme). The rest of the pipeline stays Kafka-driven — this is the
"synchronous only where a decision is needed *now*" rule from the service-boundaries doc:
whether the customer's money is authorized is exactly such a decision.

The call is wrapped in **Resilience4j** with the following policy — *parameter values are
team-proposed defaults, to be tuned after the first k6 baseline and recorded here*:

| Concern | Proposed policy | Rationale (resilience lecture) |
|---|---|---|
| **Timeout** | 2 s per attempt | every remote call needs a deadline; derived from the pipeline stage budget, leaves room for fallback |
| **Retry** | max 3 attempts, exponential backoff 250 ms → 1 s, **jitter** ±50% | bounded, jittered; safe **only because** authorize is idempotent (`Idempotency-Key` = orderId) |
| **Circuit breaker — open when** | failure rate ≥ 50% **or** slow-call (>2 s) rate ≥ 50%, over a sliding window of 20 calls (min 10) | error-rate threshold catches breakage; slow-call threshold catches the "slow death" that ties up threads |
| **Open state** | wait 30 s, then **half-open** with 5 probe calls | shields Payments while it recovers |
| **Fallback (safe failure behaviour)** | order stays `RESERVED` with a `payment_pending` marker; the authorization is **queued for retry** (redelivery via the existing Kafka stage); the client sees the order as "in progress", never an unbounded hang. If retry ultimately fails → compensation: release the reservation, order → `FAILED`. | a breaker is useful only with a safe fallback: queued + explicit, not hanging |
| **Bulkhead** | dedicated connection pool / dispatcher for the Payments WebClient, isolated from Inventory calls and from the Kafka consumers | a slow Payments must not starve the rest of Orders |

## Consequences

- **CE-1 becomes demonstrable as written**: inject latency > 2 s into Payments → breaker
  opens → fallback engages → Catalog (and Inventory reads) stay healthy. Manifest and
  report: `docs/chaos-experiments/ce-1-latency-payments.{yaml,md}`.
- **App-repo work item** (needs a YouTrack card): add Resilience4j to `orders-service`,
  implement the call + policy above, expose breaker state as a Micrometer metric
  (`resilience4j_circuitbreaker_state`) so the experiment can *show* the transition on a
  dashboard. ⚠️ Build it on the canonical Orders implementation — **blocked by decision D3**
  (EM-25 as base) until that merge happens.
- `docs/design/service-boundaries.md` updated: the sync-vs-Kafka open point is resolved.
- Payments keeps emitting `payment-authorized` for the downstream Kafka stages (audit +
  confirmation flow unchanged).

## Alternatives considered

- **Option B — stay fully async and remap resilience onto Kafka** (DLT, bounded redelivery,
  consumer-lag backpressure): less code, but deviates from the spec's explicit requirement,
  forces a redesign of CE-1, and loses the cleanest demonstration of the
  breaker/bulkhead/timeout patterns the course grades. Rejected by team vote (D1).
