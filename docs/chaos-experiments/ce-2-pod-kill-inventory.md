# CE-2 — Pod kill on Inventory mid-reservation (Chaos Mesh)

*Capstone chaos experiment #2. Automates the manual pre-test (EM-29,
[`ce-2-pod-kill-inventory-pretest.md`](ce-2-pod-kill-inventory-pretest.md)).
Injection manifest: [`ce-2-pod-kill-inventory.yaml`](ce-2-pod-kill-inventory.yaml).*

> Scientific method (resilience lecture): define steady state → state a hypothesis →
> inject ONE failure → observe on our own dashboards → conclude.
> *"Resilience that has never been tested is a hypothesis, not a property."*

## Hypothesis

Killing one Inventory Pod (SIGKILL, no grace) while reservations are in flight — and the
resulting at-least-once Kafka redelivery of `order-placed` — will **not** cause:
1. an **oversell** (`available_seats` never negative, never more seats sold than `total_seats`), nor
2. a **duplicate reservation** for the same order, nor
3. a **lost order** (every order reaches a terminal state once the pipeline converges),

because the reservation is an atomic conditional `UPDATE` (CP; row-level lock + optimistic
version), and every consumer is idempotent (`processed_events` dedup committed in the same
transaction as the business write; `UNIQUE(order_id, route_id)` on reservations).
See `docs/design/consistency.md` and `docs/design/idempotency.md`.

## Steady state (measure BEFORE injecting)

- Checkout SLIs within SLO: success rate and p95 latency on `POST /orders` (Grafana / PromQL
  from the Orders PrometheusRule).
- Kafka consumer lag for the inventory consumer ≈ 0 and stable.
- Invariants on `eurotransit-inventory-db` (queries in the pretest doc):
  - **I1**: `0 <= available_seats <= total_seats` for the test route;
  - **I2**: `total_seats - available_seats == SUM(reservations.seats)`;
  - **I3**: no duplicate `(order_id, route_id)` in `reservations`.

## Method

1. **Enable chaos on the target namespace** (once per cluster):
   ```bash
   just chaos-enable
   ```
2. Seed/reset the tiny test route (2 seats) as in the pretest doc; record steady state.
3. Start sustained concurrent load on the money path (more orders than capacity, k6 or
   the pretest driver), so reservations are actively in flight.
4. Inject — one shot, one pod:
   ```bash
   just chaos ce-2-pod-kill-inventory
   ```
5. Watch: inventory Pod restart, Kafka redelivery, consumer lag spike → drain to ~0.
6. Stop the load; wait for pipeline convergence; run the verification queries (pretest doc).
7. Clean up the chaos object:
   ```bash
   just chaos-clean ce-2-pod-kill-inventory
   ```

## What to observe (our own dashboards/queries)

- **Pod restarts**: `increase(kube_pod_container_status_restarts_total{namespace="eurotransit"}[10m])`.
- **Checkout error rate / p95** during the kill window (did the SLO burn? how much?).
- **Kafka consumer lag** for the inventory group: spike on kill, drain after restart.
- **DB invariants I1–I3** after convergence (SQL in the pretest doc).
- **Payments cross-check**: at most one authorization per order (no double charge).

## Pass / fail

- **PASS**: I1–I3 hold, no lost/stuck order, at most one payment auth per order, pipeline
  converges after the Pod restarts. A temporary latency/error blip during the kill is
  EXPECTED and acceptable (quantify it against the error budget).
- **FAIL**: any oversell, duplicate reservation, double charge, or an order stuck in a
  non-terminal state.

## Results

Full execution record (both runs, verification queries, the timestamp-boundary note):
[`ce-2-pod-kill-inventory-runs.md`](ce-2-pod-kill-inventory-runs.md).

| Date | Operator | Load / conc. | Route cap | Kill at (UTC) | Seats free at kill | Pod recovery | Lag drain | I1 | I2 | I3 | Double charge | Converged | Outcome |
|------|----------|--------------|-----------|---------------|--------------------|--------------|-----------|----|----|----|---------------|-----------|---------|
| 2026-07-12 | @giova95 | 2124 / 12 VUs | 100 | 16:45:39 | 0 (backlog drain) | new pod Ready ~30 s | → 0 | ✅ | ✅ | ✅ | none | ✅ | **PASS** |
| 2026-07-12 | @giova95 | 2152 / 12 VUs | 500 | 16:51:39 | **272 (in flight)** | new pod Ready fast | → 0 | ✅ | ✅ | ✅ | none | ✅ | **PASS (authoritative)** |

**Observations:**

- **Injection confirmed**: `Killing` event on the target pod; a **replacement** pod
  scheduled (pod-kill replaces, it does not restart in place — `restartCount` stays 0 by
  design). Run 2 caught the consumer mid-reservation: `available` fell **500 → 272 → 219
  across the crash**.
- **No oversell**: exactly **100/100** (run 1) and **500/500** (run 2) seats reserved,
  `available` never negative — through SIGKILL + at-least-once `order-placed` redelivery.
- **No duplicate reservation** (I3 = 0), **no lost/stuck order** (every cohort order
  terminal; the 500 reservations join to **500 CONFIRMED** orders — 0 orphan, 0
  non-confirmed), **no double charge** (0 orders with > 1 payment intent).
- **Containment on the sync path**: during the kill, checkout **success 100 %, 0 × 5xx,
  p95 22.2 ms, Payments breaker CLOSED** — killing the async inventory consumer consumed
  **no checkout error budget**. Kafka consumer lag spiked on the kill and drained to 0
  after the replacement pod joined.

**Dashboard captures** (native Grafana; renders in CEST = UTC+2, so the run-2 window shows
as ~18:51–18:57):

- RED money-path — [run 2](ce-2-images/ce2-run2-red-money-path.png) (success 100 %, 0 5xx,
  breaker CLOSED, lag spike→drain) and [run 1](ce-2-images/ce2-run1-red-money-path.png).
- USE infrastructure — [run 2](ce-2-images/ce2-run2-use-infrastructure.png): the inventory
  pod replaced (ready-replicas dip and recover), CPU/network of the kill+reschedule.

## Conclusion

> **Draft — pending team ratification (ADR 0019).**

The hypothesis held on every point, verified under a **mid-reservation** SIGKILL (run 2,
272 seats free at the kill): no oversell (500/500, `available` never negative), no
duplicate reservation, no lost order, no double charge. The invariants are not luck — they
follow from the design: the reservation is an **atomic conditional `UPDATE`** under a
row-level lock (CP — one winner per seat) and every consumer is **idempotent**
(`processed_events` dedup committed in the *same transaction* as the reservation, plus
`UNIQUE(order_id, route_id)`), so the at-least-once redelivery of `order-placed` after the
crash re-runs as a safe no-op on work already done. Error-budget impact of a single crash:
**zero** at the synchronous entry (100 % success, 0 × 5xx) — the failure was absorbed by
the async pipeline's redelivery, exactly where the design puts it. No tuning indicated.
