# SLO definitions

*Owner: @marcodonatucci*

> **DRAFT — starter contributed by @giova95 to save time.** RATIFY THE NUMBERS as a team.
> The owner reviews and takes ownership. Values below are *recommended defaults*, aligned with the
> alert thresholds already declared in the config `CLAUDE.md` (`CheckoutHighP95Latency` at
> p95 > 500 ms; `CheckoutHighErrorRate` at > 5% 5xx). Validate against a k6 baseline. Delete this banner once adopted.

## Checkout latency SLO

- **SLI:** p95 latency of the synchronous `POST /orders` response (client → gateway → Orders),
  excluding `/actuator/*`.
- **Target (recommended):** p95 **< 500 ms**.
- **Window:** 30 days rolling; evaluated over short windows (e.g. 5 min) for alerting.

## Checkout success-rate SLO

- **SLI:** proportion of `POST /orders` returning **non-5xx**.
- **Target (recommended):** **≥ 99.5%**.
- **Window:** 30 days rolling.
- **Judgment to record:** HTTP **429** (deliberate load shedding / backpressure) is degradation, not
  failure → **excluded** from the error numerator. Decide and state this explicitly.

## Error budget statement

- Success ≥ 99.5% over 30 days → **error budget = 0.5%** of checkout requests (≈ 216 min time-based).
- Alert on **burn rate**, not on infrastructure (no paging on CPU): fast burn (e.g. 14× / 5 min) pages
  now; slow burn (e.g. 6× / 1 h) can wait for business hours.
- **Policy:** if the error budget is exhausted, **freeze deployments on the money path** until back
  within budget (link between SLOs and progressive delivery).

## What to instrument (do not over-instrument)

- Latency SLO → request **latency histogram** (`http_server_requests_seconds_bucket`), p95 via `histogram_quantile`.
- Success SLO → request **counter** by status (`http_server_requests_seconds_count`, `status=~"5.."`).

## Open items for the owner
- [ ] Ratify targets (500 ms / 99.5%) after a k6 baseline on the real k3d cluster.
- [ ] Confirm the 429-exclusion policy.
- [ ] Set exact burn-rate windows/multipliers for the `PrometheusRule` (fast + slow burn).
