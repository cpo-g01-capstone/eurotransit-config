# CE-1 / Run 2 — Latency injection into Payments (2026-07-12, 15:39 CEST) — ABORTED

*Execution record for the **second** run of
[`ce-1-latency-payments.md`](ce-1-latency-payments.md), using the first manifest
revision produced after [run 1](ce-1-latency-payments-run-1.md). The injection was
**structurally ineffective** — the fault never reached the application path — and
the run was aborted once that was diagnosed. Kept as graded material for the
methodology lesson. The authoritative run (final manifest) is recorded in the main
report.*

## Setup

| | |
|---|---|
| Date / operator | 2026-07-12, ~15:39 CEST / @vojtech-n (Claude monitoring via Prometheus) |
| Injection | `NetworkChaos` delay 3 s ± 500 ms, **selector = orders pods, `direction: to`, target = payments pods** (the run-1 revision — see Finding) |
| Load | k6 `baseline.js`, 3 VUs, aborted at 7 m 19 s |
| T0 (injection applied) | 15:39:25, `AllInjected=True`; window expired 15:44:25 with no observable effect |

## What happened

The breaker **never opened** and the fallback counter never moved (35 → 35), despite
`AllInjected=True` on all four container records. Checkout and catalog SLIs stayed at
steady-state values throughout.

## Finding — service-VIP bypass of a source-side tc filter

Diagnosis from inside an orders pod **while the injection was active**:

| Request path | Time |
|---|---|
| `http://eurotransit-payments/...` (Service name — what the app uses) | **0.00 s** |
| `http://<payments-pod-IP>:8080/...` (direct) | **3.03 s** |

The tc filter installed on the orders pods keys on *destination pod IPs*, but the
app's packets leave the pod addressed to the **Service VIP** — on this cluster the
VIP translation bypasses the source-side filter, so application traffic is never
delayed while direct pod-IP traffic is.

**Lesson: a source-side NetworkChaos `target:` does not see through Service VIP
translation here; fault filters must sit on the side where the packets carry pod
IPs.** Final manifest shape: delay on the **payments pods' egress toward the orders
pods** (the authorize responses) — the mechanics run 1 already proved effective, now
scoped so kubelet probe responses are untouched.

## k6 record

Aborted by the operator at 7 m 19 s once the bypass was diagnosed; covers steady
state plus the entire ineffective 5-minute "window":

- `checkout_success` **100 %** (936/936), `catalog_healthy` **100 %**, 0 failed
  requests of 2997, 0 × 429 — consistent with the fault never reaching the app path.
- Breaker stayed `CLOSED` throughout.
- Client-side p95: browse_catalog 110.58 ms ✅; place_order **513.69 ms ✗** — a
  threshold breach on a *fault-free* run. With 933 iterations (vs 1914 in run 1)
  and server-side checkout p95 at 20–30 ms except a brief ramp spike (159 ms at
  15:37, cold rate window at load start), this reads as client-side WAN/TLS
  variance on a smaller sample, not a service regression. The same pattern
  reappeared larger in run 3 (859 ms client-side vs ~20 ms server-side, catalog
  inflated too) — see the main report's observations.

## Outcome

| Date | Operator | Breaker opened | Fallbacks served | Outcome |
|------|----------|----------------|------------------|---------|
| 2026-07-12 | @vojtech-n | never (fault never bit) | 0 | **ABORTED — injection structurally ineffective**; manifest revised again (final shape), re-run as the authoritative run |
