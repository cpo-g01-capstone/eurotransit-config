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

## Results (fill during the run)

| Date | Operator | Load (orders fired / concurrency) | Kill at | Pod recovery time | Lag drain time | I1 | I2 | I3 | Double charge? | Converged? | Outcome |
|------|----------|-----------------------------------|---------|-------------------|----------------|----|----|----|----------------|------------|---------|
|      |          |                                   |         |                   |                |    |    |    |                |            |         |

**Observations (dashboards/screenshots):**

*(link Grafana panels / screenshots here)*

## Conclusion

*(Did the hypothesis hold? What did we change if it did not? What did we learn about the
error-budget impact of a single pod crash?)*
