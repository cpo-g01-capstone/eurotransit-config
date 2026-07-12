# CE-1 — Latency injection into Payments (Chaos Mesh)

*Capstone chaos experiment #1. Injection manifest:
[`ce-1-latency-payments.yaml`](ce-1-latency-payments.yaml). Depends on **ADR 0018**
(synchronous Orders→Payments authorize + Resilience4j breaker).*

> ✅ **Prerequisites deployed (2026-07-11):** the Resilience4j breaker + bulkhead landed in
> `orders-service` (app PR #13, ADR 0018) and is live; the breaker-state panel is on the
> Grafana money-path dashboard (config PR #67). Steady-state baselines are available from
> the 2026-07-11 k6 run (`docs/delivery/2026-07-11-progressive-delivery-demo-results.md`).
> The experiment is ready to run.

## Hypothesis

Injecting 3 s (±500 ms) of network delay toward every Payments pod for 5 minutes will:
1. make authorize calls exceed the 2 s timeout → the Orders **circuit breaker opens**
   (slow-call rate ≥ 50% over the sliding window, ADR 0018);
2. engage the **fallback**: orders stay `RESERVED` with payment queued for retry — **no
   unbounded hang**, no thread-pool exhaustion in Orders (bulkhead holds);
3. leave **Catalog browsing healthy** (its RED panel unaffected) — the failure is
   *contained*, not propagated;
4. after the window expires and Payments latency normalizes, the breaker goes
   **half-open → closed** and queued authorizations drain to completion, with **at most
   one charge per order** (idempotency).

## Steady state (measure BEFORE injecting)

- Checkout SLIs within SLO (success rate, p95) and **breaker state = CLOSED**
  (`resilience4j_circuitbreaker_state`).
- Catalog RED panel: baseline rate/errors/duration.
- No queued/pending payment retries.

## Method

1. `just chaos-enable` (once per cluster).
2. Record steady state; start moderate mixed load: checkout traffic **plus** Catalog
   browsing traffic (the point is showing the second is unaffected).
3. Inject: `just chaos ce-1-latency-payments` (self-expires after 5 m).
4. Observe during the window (below). 5. After expiry, watch recovery: breaker
   half-open → closed, queued authorizations drain.
6. `just chaos-clean ce-1-latency-payments` (removes the object; the fault already expired).

## What to observe (our own dashboards)

- **Breaker state metric** transitioning CLOSED → OPEN (→ HALF_OPEN → CLOSED after expiry).
- **Orders**: p95 on `POST /orders` during the window (should degrade *bounded* — fast-fail
  via breaker, not 3 s hangs), no thread/connection pool saturation (bulkhead metric).
- **Catalog RED panel**: rate/errors/duration flat — the containment claim.
- **Payments**: authorize latency ~3 s (the injection working), then normal.
- **Error budget**: quantify how much of the checkout budget the 5-minute window burned.

## Pass / fail

- **PASS**: breaker opens within the window; no unbounded hangs (no request waiting > timeout
  × retries); Catalog SLIs unaffected; after expiry the system converges (breaker closed,
  queued payments completed, exactly one charge per order).
- **FAIL**: Orders threads exhaust / p95 explodes to the injected 3 s (breaker or bulkhead
  not working); Catalog degrades (cascade — containment failed); double charge on retry
  drain; breaker never closes after recovery.

## Results (fill during the run)

| Date | Operator | Load (checkout + catalog rps) | Breaker opened at | Fallbacks served | Catalog impact | Recovery (half-open→closed) | Double charges | Outcome |
|------|----------|-------------------------------|-------------------|------------------|----------------|------------------------------|----------------|---------|
|      |          |                               |                   |                  |                |                              |                |         |

**Observations (dashboards/screenshots):**

*(link Grafana panels here)*

## Conclusion

*(Did the hypothesis hold? Tune the ADR 0018 thresholds if the window/rates proved wrong.)*
