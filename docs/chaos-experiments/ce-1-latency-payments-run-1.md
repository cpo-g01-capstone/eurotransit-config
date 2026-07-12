# CE-1 / Run 1 — Latency injection into Payments (2026-07-12, 15:16 CEST)

*Execution record for the **first** run of
[`ce-1-latency-payments.md`](ce-1-latency-payments.md). This run was **terminated
early by an unhypothesized side effect** of the injection scoping — the finding below
is why the injection manifest was revised and the experiment re-run. Kept as graded
material: this is exactly the "observe honestly, conclude, correct" loop the
scientific method requires.*

## Setup

| | |
|---|---|
| Date / operator | 2026-07-12, ~15:16 CEST / @vojtech-n (Claude monitoring via Prometheus) |
| Injection | `NetworkChaos` delay 3 s ± 500 ms, **selector = payments pods, direction `to`, no `target`** (the original scoping — see Finding) |
| Load | k6 `baseline.js`, 3 VUs, 15 m, mixed checkout + catalog browse (~2.1 order/s + ~2.6 browse/s) |
| Demo route | reseeded to 5000 seats before the run (was sold out — 0/100) |
| T0 (injection applied) | ≈ 15:16:50 (between the 15:16:45 and 15:17:02 samples) |

## Steady state (measured before injection, Prometheus 15:15:51–15:16:45)

- Checkout: 2.16 req/s, **p95 28–33 ms** (server-side), 0 × 5xx
- Catalog: 2.59 req/s, **p95 1 ms**, 0 % errors
- Payments (server-side): p95 ≈ 129 ms
- Breaker: `CLOSED` on both orders pods; `not_permitted_calls_total` = 0
- No pending payment retries; orders converging normally

## Timeline (Prometheus samples, 15 s interval)

| ts | breaker (per orders pod) | checkout p95 (s) | catalog p95 (s) | checkout rps | catalog rps | fallback calls (cum.) |
|---|---|---|---|---|---|---|
| 15:16:45 | closed \| closed | 0.028 | 0.0010 | 2.16 | 2.59 | 0 |
| **15:17:02** | **open \| open** | 0.025 | 0.0010 | 2.13 | 2.56 | 10 |
| 15:17:21 | open \| open | 0.030 | 0.0010 | 2.12 | 2.55 | 13 |
| 15:17:38 | open \| open | 0.033 | 0.0010 | 2.14 | 2.55 | 17 |
| 15:17:57 | open \| open | 0.035 | 0.0010 | 2.11 | 2.51 | 21 |
| 15:18:14 | open \| open | 0.035 | 0.0010 | 2.10 | 2.51 | 29 |
| **15:18:32** | **half_open \| open** | 0.044 | 0.0010 | 1.95 | 2.36 | 34 |
| **15:18:49** | **closed \| closed** | 0.041 | 0.0010 | 1.98 | 2.39 | 35 |
| 15:19:41 | closed \| closed | 0.030 | 0.0010 | 2.06 | 2.48 | 35 (plateau) |
| 15:23:28 | closed \| closed | 0.025 | 0.0010 | 2.19 | 2.60 | 35 |

- **Breaker CLOSED → OPEN within ~15 s of T0** on both orders pods.
- **Checkout p95 stayed 25–44 ms during the whole window** — fast-fail via the open
  breaker, never the injected 3 s. The k6 client-side `max=2.17s` shows the worst
  single request (the breaker-opening transient) was bounded by the 2 s call timeout.
- **Catalog flat at p95 1 ms, rate unchanged** — the containment claim held.
- 35 authorize calls were fast-failed to the fallback (order parked `RESERVED`,
  payment queued).

## Finding — the fault self-destructed at ~2.5 min (why this run was cut short)

The original manifest selected the **payments pods** with `direction: to` and no
`target`, which delays **all egress from the payments pods — including their
liveness/readiness probe responses**. With the probes' `timeoutSeconds: 1`:

1. kubelet probe checks hit `context deadline exceeded` (events recorded at
   15:17–15:19 on both payments pods) → **liveness failures → containers killed, 3
   restarts each**. The pod network namespace (and its tc rules) survives container
   restarts, so the pods kept failing until Chaos Mesh marked the records
   `Not Injected`.
2. The restart churn (JVM boots) drove payments CPU to **304 % of the 70 % HPA
   target → HPA scaled payments 2 → 4**. The two new pods were created after
   injection and were never selected by the (already fired) chaos object.
3. Net effect: by ~15:18:40 effectively no payments traffic was delayed any more.
   The breaker probed (`HALF_OPEN` 15:18:32), the probe calls succeeded, and it
   **closed at 15:18:49 — legitimately, but ~3 min before the window was due to
   expire**.

**Lesson (fed back into the manifest):** an unscoped egress delay on a service does
not model "the network toward that service is slow" — it models "the pod is slow at
everything", which Kubernetes *by design* answers with probe kills and restarts. The
injected fault must be scoped to the caller→callee path under test.
`ce-1-latency-payments.yaml` was revised: **selector = orders pods, `direction: to`,
`target` = payments pods** — the delay now applies only to orders→payments traffic;
kubelet probes and all other flows are untouched.

*(Secondary observation, no action: kubelet converted a latency fault into a restart
fault. Our own liveness probes are local-only per the probe rules — the cascade came
from the platform's probe timeout vs the injected delay, not from a probe checking a
downstream.)*

## Convergence / integrity checks (after recovery)

- **No stuck orders**: every order from the run reached a terminal state
  (`CONFIRMED`/`FAILED`); a single in-flight row observed mid-check went terminal
  seconds later.
- **No double charge**: zero duplicate `payment_intents` per `order_id`; recent
  intents all `AUTHORIZED`, one per order.
- Payments settled back to 2/2 replicas (HPA downscale) by 15:27.

## k6 evidence (full 15 m run, includes the window)

- `checkout_success` **100 %** (1914/1914), `catalog_healthy` **100 %** — no SLO
  error-budget burn (0 failed requests of 6126, 0 × 429).
- Client-side p95: place_order **406.56 ms** < 500 ms SLO ✅, browse_catalog
  **125.69 ms** ✅ (client-side includes WAN+TLS; server-side p95 stayed ≤ 44 ms).
- Worst single request: 2.17 s (bounded by the 2 s authorize timeout during the
  breaker-opening transient — no unbounded hang).

## Outcome

| Date | Operator | Load | Breaker opened at | Fallbacks served | Catalog impact | Recovery (half-open→closed) | Double charges | Outcome |
|------|----------|------|-------------------|------------------|----------------|------------------------------|----------------|---------|
| 2026-07-12 | @vojtech-n | 2.1 order/s + 2.6 browse/s | ≤ 15:17:02 (~15 s after T0) | 35 | none (p95 1 ms flat) | 15:18:32 → 15:18:49, **early — fault self-destructed** | 0 | **INVALID as designed / VALUABLE as finding** — re-run with scoped manifest |

**Proposed conclusion (for team sign-off):** every *hypothesised* property held —
breaker lifecycle, bounded fast-fail, catalog containment, idempotent drain, no
double charge. The run is nonetheless not a valid execution of CE-1 because the
fault did not persist for the declared 5-minute window: the injection scoping
(whole-egress delay) collided with kubelet probe timeouts and destroyed itself. The
manifest was corrected to scope the delay to the orders→payments path; CE-1 is
re-run, and that re-run is the authoritative result.

## Addendum — Run 2 (first revision), aborted: service-VIP bypass

The first manifest revision put the delay on the **orders pods' egress toward the
payments pod IPs** (selector = orders, `direction: to`, target = payments). Applied
at 15:39:25; `AllInjected=True`; the breaker **never opened** and the fallback
counter never moved.

Diagnosis from inside an orders pod under active injection:

| Request path | Time |
|---|---|
| `http://eurotransit-payments/...` (Service name — what the app uses) | **0.00 s** |
| `http://<payments-pod-IP>:8080/...` (direct) | **3.03 s** |

The tc filter keys on *destination pod IPs*, but the app's traffic leaves the pod
addressed to the **Service VIP** — on this cluster the VIP translation bypasses the
source-side filter, so the app's packets are never delayed while direct pod-IP
traffic is. **Lesson: a source-side NetworkChaos `target:` does not see through
Service VIP translation here; fault filters must sit on the side where the packets
carry pod IPs.** Final manifest shape: delay on the **payments pods' egress toward
the orders pods** (responses) — the mechanics run 1 already proved effective, now
scoped so kubelet probe responses are untouched. The run was aborted (fault
expired without effect, object cleaned) and repeated with the final manifest.

**Run 2 k6 record** (aborted by operator at 7m19s once the bypass was diagnosed;
covers steady state + the entire ineffective 5-minute "window" 15:39:25–15:44:25):

- `checkout_success` **100 %** (936/936), `catalog_healthy` **100 %**, 0 failed
  requests of 2997, 0 × 429 — consistent with the fault never reaching the app path.
- Breaker stayed `CLOSED` throughout; fallback counter never moved (35 → 35).
- Client-side p95: browse_catalog 110.58 ms ✅; place_order **513.69 ms ✗** — the
  only threshold breach of the day, on the *fault-free* run. With 933 iterations
  (vs 1914 in run 1) and server-side checkout p95 at 20–30 ms except a brief ramp
  spike (159 ms at 15:37, cold rate window at load start), this reads as
  client-side WAN/TLS variance on a smaller sample, not a service regression —
  worth keeping an eye on across the remaining experiments' baselines.
