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

> **Run 1 (2026-07-12)** terminated early: the original injection scoping (whole-egress
> delay on the payments pods) collided with kubelet probe `timeoutSeconds: 1` → probe
> kills, 3 restarts per pod, HPA 2→4, fault self-destroyed at ~2.5 min. All hypothesised
> properties held while the fault was live (breaker lifecycle, bounded fast-fail, catalog
> flat, no double charge), but the window did not persist as declared —
> [`ce-1-latency-payments-run-1.md`](ce-1-latency-payments-run-1.md). **Run 2** (delay
> on orders' egress toward payments pod IPs) was aborted: the app's traffic addresses
> the Service VIP and bypassed the source-side filter — the fault never bit —
> [`ce-1-latency-payments-run-2.md`](ce-1-latency-payments-run-2.md). Final manifest:
> delay on payments' egress toward the orders pods only (responses). The table below
> records **run 3**, the authoritative run with that manifest.

| Date | Operator | Load (checkout + catalog rps) | Breaker opened at | Fallbacks served | Catalog impact | Recovery (half-open→closed) | Double charges | Outcome |
|------|----------|-------------------------------|-------------------|------------------|----------------|------------------------------|----------------|---------|
| 2026-07-12 | @vojtech-n | 2.0 + 2.4 rps (k6 baseline.js, 3 VUs, 15 m) | 15:59:33 (~23 s after T0 15:59:10) | 84 (not-permitted counter 35→119) | **none** — p95 1 ms and rate flat for the whole window | fault expired 16:04:10 → both breakers CLOSED 16:04:30 (~20 s) | **0** | **PASS** |
| 2026-07-12 | @giova95 | 2.2 + 2.7 rps (same harness, 15 m) | ≤ T0+36 s (T0 15:47:39) | 63+ not-permitted | **none** — p95 0.95 ms flat | expired 15:52:39 → CLOSED ≤ 95 s | **0** | **PASS — verification re-run, case-24 finding CLOSED** ([run 4](ce-1-latency-payments-run-4.md)) |

**Observations (Prometheus samples @15 s + DB verification; run 3, the authoritative
run with the final manifest — [run 1](ce-1-latency-payments-run-1.md) and
[run 2](ce-1-latency-payments-run-2.md) have their own records):**

- **Injection verified live**: orders→payments request via the Service took 5.51 s
  under the fault (SYN-ACK + response each delayed ~3 s) vs 0.00 s after expiry.
- **Breaker lifecycle** (per orders pod, each replica independent): CLOSED → **OPEN
  at 15:59:33** (~23 s after T0), then open ↔ half-open cycling roughly every 30–40 s
  for the whole 5-minute window — every HALF_OPEN probe correctly hit the live fault
  and snapped back to OPEN (observed at 16:00:08, 16:00:26, 16:01:21, 16:01:41,
  16:02:16, 16:02:33, 16:03:15, 16:03:53). After expiry (16:04:10) the first probes
  succeeded: **both CLOSED at 16:04:30**.
- **No unbounded hang**: checkout (`POST /orders`) server-side p95 stayed **19–21 ms
  during the entire window** (steady-state 19 ms) — the open breaker fast-failed the
  authorize step and the order parked `RESERVED`; the sync entry kept returning 202.
- **Containment**: Catalog rate ~2.4 req/s and p95 1 ms, completely flat — the
  failure did not propagate outside the Orders→Payments edge. Payments pods
  themselves: **0 restarts, 0 probe failures, HPA steady at 2** (the run-1 cascade
  is gone with the scoped manifest).
- **Queued-drain convergence** (orders DB, window cohort vs steady cohort):
  - steady-state orders (13:56–13:59 UTC): confirmed in median **0.14 s** / p95 0.37 s;
  - in-window orders (544): parked during the fault, confirmed in median **198 s** /
    p95 313 s / max 342 s — i.e. the backlog **fully drained within ~40 s of the
    breaker closing**. 0 orders stuck non-terminal.
  - **2 orders** (created 15:59:06, seconds before T0, authorize in flight when the
    fault hit) exhausted their bounded retries inside the window → compensated to
    `FAILED` via `order-failed`, **no payment intent created, no charge**. Explicit
    bounded failure, not a hang: 2 / 546 window orders (0.37 %).
- **Exactly-one-charge**: 0 duplicate `payment_intents` per order across the run.
- **Error budget**: 0 × 5xx measured for the entire run — the fault window consumed
  no success-rate budget at the sync entry (the 2 async failures surfaced as
  compensated `FAILED` orders, not 5xx).

- **k6 client-side record** (aborted by operator at 12 m 26 s — covers steady state,
  the full fault window and the recovery/drain): `checkout_success` **100 %**
  (1413/1413), `catalog_healthy` **100 %**, 0 failed requests of 4515, 0 × 429.
  Client-side p95: browse_catalog 355.36 ms ✅; place_order **859.69 ms ✗** (max
  3.65 s). Caveat on that breach: the server-side SLI of record stayed at 19–21 ms
  for checkout and **1 ms for catalog** throughout — yet the *catalog* client-side
  p95 also inflated to 355 ms, so the inflation sits between the k6 client and the
  gateway (WAN/TLS variance, same pattern flagged on the fault-free run 2 at
  513 ms), not in the services. The PrometheusRule SLIs are the measurement of
  record for the SLO; the client-side view is kept here for honesty and should be
  re-baselined from a less noisy vantage point before the demo.

### Dashboard captures (run 3, the authoritative run)

Native Grafana, `EuroTransit — RED (money path)` dashboard, run-3 window.
*(Grafana renders timestamps in CEST = UTC+2: the breaker OPEN band starts at ~15:59
on the panel = 13:59 UTC = T0+23 s. All other times in this doc are UTC.)*

- **RED money-path** — [`ce1-run3-red-money-path.png`](ce-1-images/ce1-run3-red-money-path.png):
  the **breaker state-timeline** (bottom panel) shows both orders pods CLOSED → OPEN at
  ~15:59, cycling OPEN↔HALF_OPEN through the window, back to CLOSED after expiry; **Errors
  % 5xx = No data** (zero server errors), **Checkout success (1h) 100 %**, **Checkout p95
  22.0 ms**, and the payments `rate` dipping while orders/catalog hold — containment,
  visible.
- **USE infrastructure** — [`ce1-run3-use-infrastructure.png`](ce-1-images/ce1-run3-use-infrastructure.png):
  payments CPU/restarts flat, ready-replicas steady (no probe-kill cascade — the scoped
  manifest working, contrast with run 1).

*(Rendered live from the cluster's Grafana against the monitoring stack's own Prometheus,
which is on a PVC; run-4 captures — including the case-24 guard — are in
[`ce-1-latency-payments-run-4.md`](ce-1-latency-payments-run-4.md).)*

## Conclusion

*(Draft for team sign-off — the numbers are measured, the judgement is yours.)*

The hypothesis held on all four points, with one nuance to ratify. (1) The breaker
opened ~23 s after injection and fast-failed for the full window. (2) No unbounded
hang: sync checkout p95 never left ~20 ms, and the bulkhead never saturated; orders
parked `RESERVED` and drained after recovery. Nuance: the 2 orders whose authorize
was in flight at fault onset exhausted their bounded retries and failed *explicitly*
with compensation (no charge, seats released) rather than waiting for the queue —
this is the designed bounded-retry behaviour (ADR 0018), and arguably stronger than
the "queued forever" reading of the hypothesis, but the team should ratify that
reading. (3) Catalog was untouched — containment proven. (4) Recovery: breaker
closed within ~20 s of the fault lifting and the 544-order backlog converged in
~40 s, with exactly one charge per confirmed order. No threshold tuning of ADR 0018
appears necessary: the ~30–40 s open→half-open cadence probed often enough to detect
recovery quickly without letting meaningful traffic through during the fault.

The two aborted attempts that preceded this run produced their own findings —
the probe-timeout cascade ([run 1](ce-1-latency-payments-run-1.md) — the restart/HPA
cascade is visible on that run's USE dashboard capture) and the Service-VIP bypass of
source-side tc filters ([run 2](ce-1-latency-payments-run-2.md) — its RED capture shows
the breaker never leaving CLOSED) — both candidate material for `docs/agent-log.md`.

**Follow-up closed (run 4):** run 3's 3-exhausted-vs-2-FAILED discrepancy turned out to
be a real defect (the recoverer compensated an order that had reached CONFIRMED —
agent-log case 24). Fixed in app #28 (compensation guard + counter) and **proven fixed
under the same fault**: the race reproduced on the first verification run and the guard
blocked it — the confirmed order kept its seats. Full record:
[`ce-1-latency-payments-run-4.md`](ce-1-latency-payments-run-4.md).
