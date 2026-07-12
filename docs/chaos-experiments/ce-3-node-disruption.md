# CE-3 — Node / AZ-style disruption (drain-based runbook)

*Capstone chaos experiment #3. No Chaos Mesh CR needed: the injection is a controlled
`kubectl cordon + drain` of one AKS node — the same voluntary disruption a node upgrade
produces, which is exactly what PodDisruptionBudgets govern.*

## Hypothesis

Draining one node that hosts critical-path pods will NOT make the money path unavailable:
1. **PDBs** (`minAvailable: 1` on orders/inventory/payments) prevent the drain from
   evicting the last replica of any critical service at once — the drain *waits* until a
   replacement pod is Ready elsewhere;
2. checkout keeps succeeding during the whole drain (possibly with a bounded latency blip);
3. once the node is uncordoned, the cluster rebalances and steady state returns.

## Prerequisites (blockers — verify BEFORE draining)

1. **App-pod topology spread** is in place since ADR 0023 (#42) — the original "no spread yet"
   weakness of this runbook is resolved; still verify with `kubectl get pods -n eurotransit -o wide`
   that no service has both replicas on the target node.
2. **`eurotransit-orders-db` pod anti-affinity is `required`** (CE-5 review follow-up 3): the CE-5
   pre-run check found primary AND standby on the SAME node — with CNPG's default `preferred`
   anti-affinity, draining that node is an unhypothesized DOUBLE DB failure, not this experiment.
   Verify two different nodes before injecting:
   ```bash
   kubectl get pods -n eurotransit -l cnpg.io/cluster=eurotransit-orders-db \
     -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
   ```
   Expected behaviour during the drain with `required` spread on a small pool: the evicted DB
   instance may sit **Pending until the drain ends** — that is the correct, hypothesis-consistent
   outcome (PDB + spread holding), **not a failure**; record it as such.

## Steady state

- Checkout SLIs within SLO; all Deployments at desired replicas; consumer lag ≈ 0.
- Note which node each critical pod runs on:
  `kubectl get pods -n eurotransit -o wide`

## Method

1. Record steady state and start continuous checkout + catalog load.
2. Pick the node hosting the most critical-path pods: `NODE=<name>`.
3. Inject (voluntary disruption, honours PDBs):
   ```bash
   kubectl cordon "$NODE"
   kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=10m
   ```
4. Observe (below) while pods reschedule.
5. Recover: `kubectl uncordon "$NODE"`.

## What to observe

- **Checkout SLIs during the drain** — the availability claim.
- **PDB behaviour**: `kubectl get pdb -n eurotransit` (ALLOWED DISRUPTIONS hitting 0 =
  the budget doing its job); drain events blocked/waiting.
- **Pod rescheduling time** (gap between eviction and Ready on another node) vs the
  startup-probe window.
- **Where replicas land** — evidence for/against the spread constraints (ADR 0023).

## Pass / fail

- **PASS**: no checkout outage (success-rate SLI never dips below SLO for the window);
  drain completes or is correctly *held* by a PDB; system returns to steady state on
  uncordon.
- **FAIL**: any window with 0 Ready replicas of a critical service (availability hole);
  errors surfacing to clients beyond the error budget; pods stuck Pending after uncordon.

## Results (fill during the run)

| Date | Operator | Node drained | Pods evicted | Drain duration | Checkout SLI dip | PDB held? | Findings for ADR 0023 | Outcome |
|------|----------|--------------|--------------|----------------|------------------|-----------|------------------|---------|
|      |          |              |              |                |                  |           |                  |         |

## Conclusion

*(Did the hypothesis hold? If the drain stalled or a service went to 0 replicas, feed the
finding into ADR 0023 — topology spread + anti-affinity.)*
