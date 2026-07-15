# CE-6 — Payments total outage (Chaos Mesh)

*Custom experiment beyond the five required. Injection manifests:
[`ce-6-pod-kill-payments.yaml`](ce-6-pod-kill-payments.yaml) (variant A — kill all pods,
~30 s self-heal) and [`ce-6-pod-failure-payments.yaml`](ce-6-pod-failure-payments.yaml)
(variant B — pods unresponsive for a fixed 2 m window). Run ONE variant per run.
Depends on **ADR 0018** (synchronous Orders→Payments authorize + Resilience4j breaker).*

> Scientific method (resilience lecture): define steady state → state a hypothesis →
> inject ONE failure → observe on our own dashboards → conclude.

**How this differs from CE-1 and CE-2:** CE-1 made Payments *slow* (breaker opens on
slow-call rate); CE-2 killed *one* replica of an async consumer (redelivery absorbs it).
CE-6 removes the **entire** Payments capacity at once — both HPA-baseline replicas — so
the synchronous authorize path sees hard **connection failures**, and the breaker must
open on failure rate, not slow calls. The `eurotransit-payments` PDB (`minAvailable: 1`)
does not prevent this: PDBs guard evictions, not deletions or crashes — which is exactly
why the resilience has to live in the caller, not in scheduling policy.

## Hypothesis

> **Draft — the team must ratify or rewrite this before the run (agentic coding policy:
> hypotheses are team-owned).**

Killing all Payments pods simultaneously (SIGKILL, no grace) under checkout load will:

1. cause authorize calls to fail fast with connection errors → the Orders **circuit
   breaker opens** on failure rate (ADR 0018) — no unbounded hangs, the bulkhead holds;
2. engage the **fallback**: affected orders stay `RESERVED` with payment queued for
   retry — no order is lost, none stuck in a non-terminal state after convergence;
3. leave **Catalog browsing healthy** (containment — the failure does not cascade);
4. keep the **Payments Kafka consumer** safe: `inventory-reserved` events delivered
   during the outage are redelivered/lagged, then drained after recovery, with dedup
   (`processed_events`) guaranteeing **at most one authorization per order** — the
   never-double-charge invariant holds through the crash;
5. recover without intervention: the Deployment replaces both pods (variant A: Ready in
   ~30 s; variant B: after the 2 m window), breaker goes half-open → closed, queued
   authorizations drain.

## Steady state (measure BEFORE injecting)

- Checkout SLIs within SLO (success rate, p95 on `POST /orders`); breaker **CLOSED**
  (`resilience4j_circuitbreaker_state`).
- Payments consumer lag ≈ 0 and stable; no queued/pending payment retries.
- `paymentsdb`: no order with more than one `payment_intents` row
  (`just seed-db status` prints `orders_with_multiple_intents`).
- Catalog RED panel: baseline rate/errors/duration.

## Method

1. `just chaos-enable` (once per cluster).
2. Seed a known state — the throughput route works fine here: `just seed-db ce-1`
   (route `...0001`, 5000 seats).
3. Record steady state; start sustained mixed load: checkout traffic **plus** Catalog
   browsing (the containment claim needs the second stream).
4. Inject — one shot, all payments pods:
   ```bash
   just chaos ce-6-pod-kill-payments        # variant A: kill, ~30 s outage
   # OR (not both):
   just chaos ce-6-pod-failure-payments     # variant B: unresponsive for 2 m
   ```
5. Watch: endpoints for `eurotransit-payments` go empty → breaker CLOSED → OPEN →
   replacement pods Ready → HALF_OPEN → CLOSED; payments consumer lag spike → drain.
6. Stop the load; wait for pipeline convergence; run the verification queries.
7. Clean up: `just chaos-clean ce-6-pod-kill-payments` (or `...pod-failure...`).

## What to observe (our own dashboards/queries)

- **Breaker state** transitions (CLOSED → OPEN → HALF_OPEN → CLOSED) and *what opened
  it*: failure rate this time, not slow-call rate — compare with CE-1.
- **Orders `POST /orders`**: p95 and error/fallback split during the window — degradation
  must be *bounded* (fast-fail via breaker, not connect-timeout hangs).
- **Ready replicas** for `eurotransit-payments`: 2 → 0 → 2, and how long 0 lasted.
- **Payments consumer lag** (`inventory-reserved` group): spike during outage, drain after.
- **Catalog RED panel**: flat — the containment claim.
- **`CheckoutHighErrorRate` / `CheckoutHighP95Latency`**: did the symptom alerts fire as
  designed? Quantify the error-budget burn of the window.
- **DB verification after convergence:**
  - every order in the load cohort reaches a terminal state (`CONFIRMED` / `FAILED`);
  - `paymentsdb`: zero orders with more than one payment intent (no double charge);
  - orders that failed authorization released their seats (`order-failed` compensation):
    inventory invariants I1/I2 still hold on the test route.

## Pass / fail

- **PASS**: breaker opens within the outage window; no unbounded hangs; Catalog SLIs
  unaffected; both pods replaced without intervention; after recovery the breaker closes,
  queued authorizations drain, every cohort order terminal, **zero double charges**, and
  seats reconcile (I1/I2). A bounded checkout degradation during the window is EXPECTED —
  quantify it against the error budget rather than calling it a failure.
- **FAIL**: Orders threads/pool exhaust (bulkhead broken); Catalog degrades (cascade);
  any double charge after the retry drain; any order stuck non-terminal; breaker never
  closes after Payments returns; seats leaked (reserved but order FAILED without release).

## Results

*Fill during the run — one row per run, CE-2 table style.*

| Date | Operator | Variant | Load / conc. | Kill at (UTC) | 0-replica window | Breaker opened | Breaker closed | Lag drain | Double charge | Stuck orders | Seats reconcile | Outcome |
|------|----------|---------|--------------|---------------|------------------|----------------|----------------|-----------|---------------|--------------|-----------------|---------|
|      |          |         |              |               |                  |                |                |           |               |              |                 |         |

## Conclusion

*Team-authored after the run (agentic coding policy). Record what the data showed, not
what the hypothesis hoped.*
