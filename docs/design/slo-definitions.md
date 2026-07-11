# SLO definitions

*Owner: @marcodonatucci*

**Ratified by the team on 2026-07-11 (decision D2).** Numbers below are the voted targets and are
the single source of truth for alert thresholds, dashboard stat-panel thresholds, and canary
promotion criteria (D6). Any change requires a new team vote.

## Checkout latency SLO

- **SLI:** p95 latency of the synchronous `POST /orders` response (client → gateway → Orders),
  excluding `/actuator/*`.
- **Target (ratified):** p95 **< 500 ms**.
- **Window:** 30 days rolling; evaluated over short windows (5 min) for alerting
  (`CheckoutHighP95Latency`).

## Checkout success-rate SLO

- **SLI:** proportion of `POST /orders` returning **non-5xx**.
- **Target (ratified):** **≥ 99%**.
- **Window:** 30 days rolling.
- **Ratified judgment:** HTTP **429** (deliberate load shedding / backpressure) is degradation, not
  failure → **excluded from the error numerator** (it counts as a handled response). The numerator
  is `status=~"5.."` only, so 429s never consume error budget.

## Error budget statement

- Success ≥ 99% over 30 days → **error budget = 1%** of checkout requests (≈ 432 min time-based).
- **Alert on burn rate, not on raw infrastructure.** Multi-window burn-rate alerts on the checkout
  SLI (recording rules in `templates/orders/prometheusrule.yaml`):
  - **Fast burn — page:** burn rate > **14×** on both the **5 min** and **1 h** windows
    (`CheckoutErrorBudgetFastBurn`, severity `critical`). At 14× the monthly budget is gone in
    ≈ 2 days — someone must look now.
  - **Slow burn — ticket:** burn rate > **6×** on both the **1 h** and **6 h** windows
    (`CheckoutErrorBudgetSlowBurn`, severity `warning`). At 6× the budget lasts ≈ 5 days — fix
    within business hours.
- **CPU is never a paging signal.** The ratified decision adds one **non-paging capacity ticket**
  (`MoneyPathCpuSaturationHigh`, severity `warning`): CPU > 80% of the container limit for 10 min
  on a money-path pod. It is a saturation early-warning (USE), not a symptom alert — if users are
  affected, the burn-rate alerts page independently. This is the agreed reading of "burn rate +
  CPU" that stays compatible with the repo policy "no cause-based paging".
- **Deploy-freeze policy (ratified):** if the checkout error budget is exhausted, **deployments to
  the money-path services (Orders, Inventory, Payments) are frozen** — no canary promotions, no
  blue/green switches, image-tag bumps to those services are reverted — until the 30-day SLI is
  back within budget. Platform/observability changes and bug fixes that restore the budget are
  exempt. This is the link between SLOs and progressive delivery.

## What to instrument (do not over-instrument)

- Latency SLO → request **latency histogram** (`http_server_requests_seconds_bucket`), p95 via `histogram_quantile`.
- Success SLO → request **counter** by status (`http_server_requests_seconds_count`, `status=~"5.."`).
- Burn rate → recording rules `eurotransit:checkout_error_ratio:rate<5m|1h|6h>` over the same counter.

## Decision log

- [x] Targets ratified: p95 < 500 ms / success ≥ 99% (D2, 2026-07-11). To be re-validated against
      the k6 baseline (T9); if the baseline contradicts them, re-vote.
- [x] 429-exclusion policy confirmed: 429 is not an error.
- [x] Burn-rate windows/multipliers fixed: 14× (5 m + 1 h) page · 6× (1 h + 6 h) ticket.
- [x] CPU: non-paging capacity ticket only (>80% of limit, 10 min, money path).
- [x] Error-budget policy: deploy freeze on the money path until back within budget.
