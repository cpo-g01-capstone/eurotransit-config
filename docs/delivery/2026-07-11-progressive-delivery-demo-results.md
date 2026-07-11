# Progressive delivery — demo run results (2026-07-11)

*Execution record for the progressive-delivery work (ADR 0026, runbook in `progressive-delivery-runbook.md`) plus
the first k6 baseline. Every phase below is a merged PR — the rollout history IS
the Git history. All measurements taken from Prometheus (canary/green-scoped
ServiceMonitors) and k6 client-side summaries, against the public gateway
`https://eurotransit.vojtechn.dev`.*

**Git trail:** #54 (wiring + ADR 0026) → #58 (canary start) → #59 (canary promote) →
#61 (green up) → #62 (switch) → #63 (cleanup). Candidate SHA == stable SHA on both
patterns: this run proves the MECHANICS at zero behavioural risk; the next real
version bump reuses the same commits with a different tag.

---

## 0. Context: the system this was demonstrated on

Earlier the same day, the first real order ever pushed through the gateway peeled
four invisible fault layers off the write path (agent-log cases 17–20: dead
`save()` inserts, legacy NOT NULL columns, undeliverable cross-service events, and
a frozen catalog cache + DLT'd notifications). By demo time the full money path was
live and verified: **POST → 202 → RESERVED → authorize → CONFIRMED in ~1–7 s**,
idempotent replay returns 200 with the cached body, notification logged, catalog
cache decrementing in real time, never-oversell confirmed at the DB
(atomic conditional UPDATE, optimistic-lock versions advancing).

## 1. k6 baseline — first official run

20 minutes, 3 VU, checkout+browse mix on the 100-seat route, thresholds = the
ratified SLOs (docs/design/slo-definitions.md).

| Metric | Result | Threshold |
|---|---|---|
| `place_order` p95 (client) | **96.9 ms** | < 500 ms ✅ (5× margin) |
| `browse_catalog` p95 (client) | **120.5 ms** | < 500 ms ✅ |
| HTTP failures | **0 / 9 758** | ≥ 99.5% success ✅ |
| 429 shed | 0 | (excluded from errors by design) |
| Checkouts completed | 3 049 (~2.5/s) | — |

Reading for the team: the real p95 (~100 ms) confirms the ADR 0018 breaker knobs
(slow-call 2 s) are conservative, and gives the canary promotion gate (300 ms) a 3×
margin — both tunable after the chaos runs.

## 2. Canary on Orders — promotion gate held → PROMOTE

**Phase 1 (#58):** `canary.enabled=true, weight 10, tag = stable SHA`. Canary pod
Ready, weighted TraefikService at 90/10, dedicated ServiceMonitor scraping.

**Gate window** (sustained 5 minutes under k6, canary-scoped metrics only):

| Reading | Value | Ratified gate |
|---|---|---|
| Measured split | **10.06 %** (0.49 vs 4.42 req/s) | 10 % intended |
| Canary 5xx rate | **0.0 %** | < 1 % ✅ |
| Canary latency | server-side MAX **32 ms**; k6 client p95 < 120 ms | p95 < 300 ms ✅ |

**Phase 2 (#59):** gate held → promote; weighted service collapsed to stable 100 %,
canary track torn down. Verified on-cluster (no `track=canary` pods, weight 100).

**Finding (agent-log case 20, fixed in app #24 during the demo):** the runbook's
p95 PromQL returned `no data` — `http.server.requests` published no histogram
buckets, so every p95 dashboard panel and `CheckoutHighP95Latency` had been
structurally mute since day one. After the fix: 3 268 `_bucket` series;
`histogram_quantile` p95 for `POST /orders` = **49.7 ms**. The latency SLO is now a
measurement, not a claim.

## 3. Blue/green on Catalog — clean observation window → cleanup

**B1 (#61):** green track up (2 pods), traffic on blue. Validated WITHOUT traffic:
AP cache converged by replaying **198** `inventory-reserved` events from earliest
(per-instance broadcast group); availability served by green **identical to blue**
(queried against the green Service directly).

**B2 (#62):** `activeTrack: green` — atomic cutover at the IngressRoute, verified
from outside (200s), blue kept running as the instant-rollback path.

**Observation window (ratified, ADR 0026)** (opened 17:26:21Z, 5 clean minutes under k6):

| Reading | Value |
|---|---|
| Green traffic | 1.97 req/s (k6 6 min, all thresholds green) |
| Green 5xx rate | **0** |
| Green p95 (`histogram_quantile`) | **2.2 ms** |
| Blue user traffic | **0 req/s** → cutover was total |

**B3 (#63):** cleanup — route back to blue, green torn down. The cleanup commit is
mechanically identical to a rollback (an `activeTrack` flip): rollback is a
one-commit revert at any point of the window, by construction.

**Exercised live during the window:** the k6 run targeted the 2-seat route, so the
sold-out compensation path (`InsufficientSeats`, non-retryable → recoverer publishes
`order-failed(SOLD_OUT)` → Orders marks the order FAILED — the seat-release compensation plus the audit fix merged in app #19) ran
repeatedly in production while the freshly-switched catalog served browse traffic
unaffected. Ready-made steady-state material for CE-2.

## 4. What this buys the chaos sessions

- Steady-state SLIs now have REAL baselines: checkout p95 ≈ 100 ms client / 50 ms
  server, error rate 0 %, conversion latency 1–7 s.
- p95 is finally observable server-side (bucket fix) — CE-1's "breaker opens, p95
  contained" hypothesis can be measured on the intended dashboards.
- The canary/green tracks stay available as demo assets for the recorded video:
  same commits, different tag.
