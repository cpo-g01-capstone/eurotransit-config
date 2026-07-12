# ADR 0023 — HPA for the contended services, topology spread, PDB completion

- **Status:** Proposed (this PR is the ratification vehicle)
- **Date:** 2026-07-11
- **Author:** @giova95 (resilience)
- **Related:** ADR 0021 (HA replicas), #41 (CPU-request trim), CE-3 (node drain),
  capstone Pillar C ("Kubernetes-level resilience configured deliberately rather than defaulted")

## Context

Three gaps remained in the chart's Kubernetes-level resilience:
1. only Catalog had an HPA — Inventory (the contended money-path service) and Payments
   (now on the synchronous authorize path, ADR 0018) could not scale;
2. no topology spread/anti-affinity anywhere: the scheduler could pack every replica of
   a service onto one node — "2 replicas" that die together are 1 failure domain;
3. no PDBs for catalog/notifications.

## Decision

1. **HPA for Inventory and Payments**: min 2 → max 4, CPU target 70%.
   - *Why CPU, knowingly imperfect:* the truer scaling signal for consumers is Kafka
     lag / queue depth (scaling pods only helps when pods are the bottleneck — a
     saturated downstream makes CPU-scaling feed the spiral). Custom-metric HPA needs
     prometheus-adapter; deferred. CPU@70% is safe for our I/O-bound services because
     throttling (visible on the USE dashboard) degrades latency before saturation.
   - *Why max 4:* budget arithmetic. 6 vCPU minus operators/monitoring/3-broker Kafka/
     4 CNPG clusters leaves ~limited headroom; worst-case app requests with both HPAs
     maxed stay within it thanks to the #41 trim (150m requests).
2. **Topology spread on all five Deployments** (helper `eurotransit.topologySpread`):
   maxSkew 1 across `kubernetes.io/hostname` AND `topology.kubernetes.io/zone`,
   **whenUnsatisfiable: ScheduleAnyway** (soft).
   - *Why soft:* on a small node pool a hard constraint can leave pods Pending during
     drains and rollouts — trading an availability risk for a scheduling deadlock.
     CE-3 (node drain) is the designed test of whether soft spreading suffices; if it
     records co-location under pressure, flip to DoNotSchedule zone-level only.
   - *Why spread constraints and not pod anti-affinity:* spread handles N replicas
     evenly with one primitive and per-domain skew control; binary anti-affinity adds
     nothing on top and costs another block in every pod spec.
3. **PDB completion**:
   - catalog: `minAvailable: 1` (its HPA floor is 2 — always satisfiable);
   - notifications: **`maxUnavailable: 1`, deliberately** — it runs a single
     best-effort replica; `minAvailable: 1` would make every node drain hang forever.
     The PDB exists to make the eviction policy explicit, not to block it: unacked
     records redeliver after rebalance and checkout is unaffected (its contract).

## Consequences

- CE-3 gains its full meaning: PDBs hold the money path, spread keeps replicas in
  separate failure domains, and the report has knobs to tune with evidence.
- The USE dashboard's "ready vs desired" and throttling panels are the observation
  points for both mechanisms.
- Follow-up (out of scope): prometheus-adapter for lag-based scaling of Inventory.
- Addendum (2026-07-12, CE-5 finding): the spread decision now also covers the **orders-db
  CNPG cluster** — CE-5's pre-run check caught primary and standby on the same node (CNPG
  default anti-affinity is `preferred`, which loses on a small pool).
  `postgres/eurotransit-orders-db.yaml` enforces `podAntiAffinityType: required` on
  `kubernetes.io/hostname`; CE-3's runbook lists this as a prerequisite.
