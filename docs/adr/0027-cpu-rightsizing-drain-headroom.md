# ADR 0027 — CPU-request rightsizing for drain headroom within the vCPU quota; Traefik gateway HA

- **Status:** Proposed (the rightsizing PR is the ratification vehicle)
- **Date:** 2026-07-13
- **Author:** @vojtech-n (delivery; drafted with agent assistance per the agentic coding policy)
- **Related:** ADR 0001 (cluster sizing), ADR 0005 (6 vCPU quota cap), ADR 0021 (HA
  replicas), ADR 0023 (HPA/spread/PDB; flags the CPU-signal weakness), CE-3 run 1
  (`docs/chaos-experiments/ce-3/ce-3-node-disruption.md`)

## Context

CE-3 run 1 (node drain, 2026-07-12) was an honest FAIL of the availability hypothesis:
checkout degraded to 8.88 % client-side errors because the three `B2s_v2` nodes sat at
**91–96 % CPU-requests** — a drained node's pods had nowhere to reschedule, and the
resulting churn cascaded through probe timeouts. The run's recommendation #1 ("add a
4th node / temporary scale-up before drains") is **infeasible**: ADR 0005 documents the
Azure-for-Students regional quota as ~6 vCPU with the increase request already denied.
3 × B2s_v2 consumes the entire quota.

Measurements (2026-07-13) show the saturation is reservation, not load:

| Workload | CPU request | CPU actual |
|---|---|---|
| CNPG instances (5 pods) | 250m each | 7–37m |
| Kafka brokers (3) | 250m each | ~20m |
| App services (8 pods) | 100m each | 3–7m |
| Nodes overall | 91–96 % requested | **12–25 % used** |

Run 1 also exposed the gateway as a SPOF: Traefik ran a single replica, and during the
drain the edge returned no response for ~1 minute.

## Decision

Create N+1 drain headroom by **rightsizing CPU requests** (~1250m freed), staying
within the quota; make the gateway HA:

1. **CNPG instances: 250m → 100m** (all four clusters; limits stay 500m). Frees 750m.
2. **Kafka brokers: 250m → 150m** (limits stay 500m). Frees 300m. Deliberately kept
   above the app pods: requests set the CFS share under contention, and brokers are
   the most latency-sensitive shared dependency.
3. **The four 2-replica services (catalog/orders/inventory/payments): 100m → 75m**
   (limits stay 500–1000m). Frees 200m. Second round after the 2026-07-11 trim.
4. **Traefik: 2 replicas, required per-node anti-affinity, PDB `minAvailable: 1`** —
   a voluntary drain always leaves one gateway serving. No CPU requests, consistent
   with the other platform components on this pool; the headroom budget is spent on
   the app namespace.

Deliberate **non-changes**, stated:
- **Kafka memory request stays 768Mi** — brokers use ~650Mi; a cut risks OOM during
  rebalance/drain churn. Memory, not CPU, is now the binding resource (~75–90 % real
  usage per node) and the known risk for the CE-3 re-run.
- **HPAs untouched** — but note: HPA targets are a *percentage of request*, so 75m
  requests make JVM startup bursts read hotter (ADR 0023's known CPU-signal
  weakness). The CE-3 re-run observes this; if HPAs flap on rollouts, revert the
  service requests to 100m and take the headroom elsewhere.

Resulting drain arithmetic (the schedulability check CE-3 run 2 records pre-flight):
total requests ≈ 4074m; a drained node's movable pods (≈1450m − ≈370m daemonsets)
fit into 2 × ≈1911m allocatable with ≈120m slack.

## Alternatives considered

- **4th node / bigger nodes** — quota-capped at 6 vCPU, increase denied (ADR 0005).
- **Reduce replica counts for the experiment window** — violates the premise CE-3
  exists to test (2 replicas + spread + PDB minAvailable 1); would prove nothing.
- **Scale down monitoring/chaos infrastructure during drains** — blinds the very
  observability the experiment depends on; monitoring already requests only ~100m.
- **Cut memory requests too** — unsafe: Kafka RSS ~650Mi vs 768Mi request; the JVM
  services measure 250–370Mi vs 256–384Mi requests. No meaningful safe margin.
- **CPU requests for Traefik** — rejected for now: +100–200m would consume most of
  the freed slack; platform components on this pool run request-less by precedent.

## Consequences

Easier: a single-node drain is schedulable (CE-3 re-run, node upgrades, the live
demo); the gateway survives node loss; the money-path services keep generous limits
for real burst.

Harder / risks:
- Lower requests = smaller guaranteed CFS share under real CPU contention. Mitigated
  by ordering: brokers (150m) > services (75m) > DBs (100m, near-idle), and by actual
  usage being ~5 % of the old requests.
- Applying the change **rolls pods**: CNPG rolls all DB instances (brief interruption
  on the three single-instance DBs) and Strimzi rolls brokers one-by-one. Merge in a
  quiet window, never during an experiment or canary.
- HPA startup-burst sensitivity (above).
- Memory is now the acknowledged binding constraint; if the CE-3 re-run degrades on
  memory pressure, that is a *new finding* feeding back into this ADR, not a botched run.

## Verification & ownership (agentic-coding policy)

Numbers were measured on the live cluster (2026-07-13); the team must verify before
ratification:

- [ ] Post-sync: per-node CPU-requests ≤ ~75 %; all pods Running, none Pending
- [ ] Two Traefik pods on two different nodes; `kubectl get pdb -n traefik` shows the budget
- [ ] No HPA flap / probe failures in the 24 h after rollout
- [ ] CE-3 run 2 executed against this configuration and its outcome recorded (either
      the PASS this ADR predicts, or a new finding — e.g. memory pressure — fed back here)

## References

- CE-3 run 1: `docs/chaos-experiments/ce-3/ce-3-node-disruption.md` (root cause + recommendations re-scoped here)
- ADR 0005 (quota), ADR 0021 (why 3 brokers / 2 DB instances exist at all), ADR 0023 (HPA signal)
- Rightsizing precedent: values.yaml round 1 (2026-07-11, follow-up to #46); Kafka
  heap + entity-operator memory trims (2026-07-11)
