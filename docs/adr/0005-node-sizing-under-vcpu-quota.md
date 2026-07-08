# ADR 0005 — Node sizing under regional vCPU quota (3× B2s_v2)

- **Status:** Proposed
- **Date:** 2026-07-08
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** platform, cost, aks, quota
- **Supersedes / Superseded by:** amends the node-sizing decision in ADR 0001

---

## Context

Bootstrapping the platform onto AKS (`aks-eurotransit-g01`, Poland Central) failed
to schedule: the single `B4als_v2` node hit its **max-pods cap (30)** with the
platform operators still `Pending`. The remedy in ADR 0001 is to scale to
**3× `B4als_v2`** (12 vCPU) — but scaling out failed:

```
Insufficient regional vcpu quota left for location polandcentral.
left regional vcpu quota 2, requested quota 8.
```

The Azure-for-Students subscription caps **Total Regional vCPUs at ~6** in Poland
Central (4 consumed by the current node, 2 free). A quota-increase request was
**submitted and denied** — the student tier generally will not raise it. So ADR
0001's `3× B4als_v2` target (12 vCPU) is **infeasible**, and this must be solved
by *sizing within 6 vCPU*, not by acquiring more.

Two hard requirements still stand:
- **≥3 nodes** — chaos experiment #3 (node/AZ-style disruption, PDBs, topology
  spread) and the operator anti-affinity need more than one node.
- **Enough RAM** — the resident platform stack is ~10–14 GB (ADR 0001). The
  `B2als_v2` (4 GB) node is too small; that was already rejected in ADR 0001.

## Decision

**Run the cluster on `3× Standard_B2s_v2`** (2 vCPU / 8 GB each):
- **6 vCPU total** — fits exactly inside the 6-vCPU regional quota, so the cluster
  is **quota-independent**: no dependency on an Azure approval that was refused.
- **24 GB RAM** (~18 GB schedulable) — comfortably holds the ~10–14 GB stack.
- **3 nodes × 30 max-pods = 90 pod slots** — clears the pod-count wall that
  blocked the bootstrap, and satisfies the multi-node chaos requirement.

This is ADR 0001's own documented fallback ("`B2s_v2` … if `B4als_v2` is
unavailable"), now promoted to the chosen SKU. The SKU of a node pool is
immutable, so this is a **node-pool rebuild**, executed **within the 6-vCPU
ceiling at every step** (you cannot hold `B4als_v2` (4) + `3× B2s_v2` (6) = 10 at
once):

```bash
RG=rg-eurotransit-g01; CL=aks-eurotransit-g01
# 1. Add a System-mode B2s_v2 pool (1 node = 2 vCPU → total 6, free 0).
az aks nodepool add -g $RG --cluster-name $CL -n sysb2s \
  --mode System --node-vm-size Standard_B2s_v2 --node-count 1
# 2. Delete the old B4als_v2 pool (frees 4 vCPU). Allowed: sysb2s is now System-mode.
az aks nodepool delete -g $RG --cluster-name $CL -n system
# 3. Scale the B2s_v2 pool to 3 (2 + 4 = 6 vCPU total).
az aks nodepool scale -g $RG --cluster-name $CL -n sysb2s --node-count 3
```

Between steps 2–3 the stack is briefly on one node (pods `Pending`); it converges
once step 3 lands. Cost discipline from ADR 0001 is unchanged (`az aks stop`/
`scale` when idle; 6 vCPU ≈ the same ~$0.26/hr as the 3× B4als plan).

## Alternatives considered

- **Retry the quota increase (request 12, or 8 for 2× B4als_v2).** Rejected as the
  primary path — a smaller increase was just denied, approval has lead time the
  one-week deadline can't absorb, and 8 vCPU still only buys 2 nodes. May be
  retried opportunistically, but the plan must not depend on it.
- **Keep 3× B4als_v2 (ADR 0001).** Infeasible — needs 12 vCPU vs the 6 available.
- **Minimal 2 nodes (`B4als_v2` + `B2als_v2`, 6 vCPU).** Unblocks scheduling with a
  single `nodepool add`, but only 2 nodes (weak node-disruption demo) and 12 GB
  RAM (tight). Fine as a stopgap to finish EM-34, not as the target.
- **`3× B2als_v2` (2 vCPU / 4 GB = 6 vCPU).** Fits quota and gives 3 nodes, but
  12 GB total RAM is below the stack's ~10–14 GB resident need — the same
  too-little-RAM reason ADR 0001 rejected `B2als_v2`.
- **Different region with more quota.** Rejected — DNS/resources are pinned to
  Poland Central (ADR 0001); a region move is a full rebuild, not worth it now.

## Consequences

- **Positive:** the cluster no longer depends on an Azure quota grant; the
  bootstrap can proceed today. 3 real nodes keep chaos experiment #3 in scope.
  24 GB RAM has headroom for canary/blue-green (two versions side by side).
- **Negative / risk:**
  - **CPU is tight.** 6 vCPU across the platform + five JVMs + Prometheus (ADR
    0001 flagged `B2s_v2` as "CPU tight"). Fine at idle/demo load; may throttle
    under k6 stress — watch `container_cpu_cfs_throttled` and cap k6 accordingly.
  - **Zero vCPU headroom.** At 6/6 there is no room for a surge node, so node-pool
    *upgrades* must use `--max-unavailable` (not the default max-surge, which needs
    spare quota). Note this before any AKS version bump.
  - **Rebuild is disruptive.** Deleting the `B4als_v2` pool reschedules all
    platform pods; transient `Pending` until the B2s_v2 pool reaches 3. No PVC
    data at risk for the current test (staging has no Kafka/PG; Prometheus is
    emptyDir) — but revisit PV/zone binding once stateful workloads use disks.
  - **Amends ADR 0001:** its `3× B4als_v2` sizing is replaced by `3× B2s_v2`; the
    budget, naming, RBAC, and stop/scale discipline in 0001 are otherwise intact.

## Capacity budget and operating discipline

`3× B2s_v2` is **enough to demonstrate every capstone requirement, but with
near-zero CPU slack** — it is not enough to run everything at generous replicas
under sustained load simultaneously. Sizing must be treated as a budget, not
headroom.

**Allocatable (after AKS reservations, ~150m CPU + ~1.5 GB RAM per node):**
~**5.5 vCPU**, ~**18–19 GB RAM**, **90 pod slots** (3 × 30 max-pods).

**Steady-state request estimate (full stack):**

| Component | RAM | CPU |
|---|---|---|
| kube-prometheus-stack (Prom + Grafana + Alert + exporters) | ~2–3 GB | ~0.5 |
| Argo CD | ~1 GB | ~0.5 |
| Operators (cert-manager, traefik, strimzi, cnpg, sealed-secrets, Chaos Mesh, Tempo) | ~2–3 GB | ~1.0 |
| Kafka (1 broker) + Postgres (primary + standby) | ~2–2.5 GB | ~1.0 |
| 5 JVM services × 2 replicas | ~3.5–4 GB | ~1.3 |
| kube-system | ~1 GB | ~0.5 |
| **Total** | **~12–15 GB** | **~4.8–5.5 vCPU** |

**Verdict:** RAM is comfortable (~18 GB vs ~12–15 GB). **CPU is the binding
constraint** (~5.5 allocatable vs ~4.8–5.5 requested) — fine at idle/demo, but it
**throttles under k6 load or chaos**, which can inflate money-path p95 from the
*cluster*, not the app. Read SLO dashboards with that in mind. Pod slots are OK
(~60–70 of 90), but canary/blue-green temporarily doubles some app pods.

**Operating discipline required to stay within budget:**
- **1 Kafka broker**, not 3 (partition chaos still demoable via network fault; only
  broker-quorum loss is given up).
- **Postgres primary + 1 standby** (2 instances) — enough for failover chaos #5.
- **App at 1–2 replicas**; **tear down the canary/blue-green second version right
  after demoing** it, don't leave both running.
- **Prometheus short retention / low cardinality** (ADR 0001's ~10–20 GB).
- **Moderate k6 VUs** — prove behaviour, not capacity; watch
  `container_cpu_cfs_throttled_seconds`.
- **Never run staging + prod full stacks at once** — this is why `eurotransit-staging`
  is scoped to app-chart-only, 1 replica, no Kafka/PG.

**Safety net (ADR 0001 model):** develop on local k3d; AKS carries only the
integration/demo/chaos runs. If a run is still too tight, scale down what isn't
under test, or run heavy chaos on k3d and reserve AKS for the public-HTTPS +
node-disruption demos. Validate against the real numbers, not this estimate:
`kubectl top nodes`, `kubectl top pods -A --sort-by=memory`, and any `Pending`
pod means over budget.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance during the live AKS bootstrap. Before ratifying:

- [ ] Confirm `Standard_B2s_v2` is offered in Poland Central for this subscription.
- [ ] Confirm the regional/`BALSv2`-family vCPU limits actually allow `3× B2s_v2`
      (6 vCPU) — check `az vm list-usage -l polandcentral`.
- [ ] After the rebuild, confirm 3 nodes `Ready`, all platform apps Synced/Healthy,
      and no pods `Pending` for "Too many pods".
- [ ] Under k6 load, confirm CPU throttling stays acceptable on the money path; if
      not, reduce replica counts or k6 VUs, and record it in `docs/agent-log.md`.
- [ ] Team ratifies replacing ADR 0001's `3× B4als_v2` with `3× B2s_v2`.

## References

- ADR 0001 (AKS sizing/budget — the amended sizing; `B2s_v2` fallback row).
- Azure quota error (Poland Central, Total Regional vCPUs) and increase denial.
- `just aks-bootstrap` (brings the stack up once the nodes exist).
- Azure quotas: <https://learn.microsoft.com/azure/quotas/view-quotas>.
