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

## Results

*Executed 2026-07-12, @giova95 (Claude driving kubectl + load, per session authorization;
ADR 0019 gate). Prerequisites set first: the hard per-node spread (#81) put every
2-replica money-path service on two nodes before the drain. This is an **honest FAIL of
the availability hypothesis** on the current cluster — the most valuable kind of chaos
result: a tested hypothesis that did not hold, with a clear root cause.*

| Date | Node drained | Load | Drain result | Checkout during drain | Data integrity | PDBs | Outcome |
|------|--------------|------|--------------|-----------------------|----------------|------|---------|
| 2026-07-12 | `…q` (orders, payments, catalog replicas + orders-db-1 **primary**) | k6 5 VUs on the money path | **did NOT complete** — held at the 2m30s timeout on `coredns`/`metrics-server` (kube-system) | **degraded: 8.88 % failed (135/1520 req)** over the ~4-min window, a ~1-min hard gap (curl returned `000`) | ✅ **0 lost/duplicate** — 420 in-window orders all CONFIRMED | held (DBs protected) | **FAIL (hypothesis not held) — capacity finding** |
| 2026-07-13 | `…s` (most critical-path pods, 2 brokers, orders-db primary — switched over first) | k6 5 VUs, pristine seed | **completed, 6 m 06 s** | **0.008 % failed (1/12,448)**, success 100 % | ✅ 3889 = 3889, 0 lost/duplicate | Kafka PDB sequenced the 2-broker eviction | **PASS — re-run after the capacity fix (PR #89)** ([run 2](ce-3-node-disruption-run-2.md)) |

**Timeline (UTC):** T0 cordon+drain `…q` 17:32:08 → cascade of probe failures 17:32–17:36
→ uncordon 17:36:17 → checkout restored 17:37:11.

**What HELD (the resilience patterns worked):**
- **Hard spread (#81):** every money-path service kept ≥1 replica on a non-drained node —
  no service hit 0 by scheduling. The prerequisite fix did its job.
- **PDBs protected state:** the drain was correctly *held* (never completed) — it could not
  evict the DB primaries (`ALLOWED DISRUPTIONS = 0`) or the last kube-system singletons.
- **CNPG failover:** `orders-db` primary moved `db-1 → db-2` during the disruption; cluster
  stayed **healthy 2/2, RPO 0** (the CE-5 property, seen again here for free).
- **Data integrity:** 420 in-window orders, all CONFIRMED, **zero lost, zero duplicate** —
  idempotency + the DB held through the turbulence even as availability dipped.

**What did NOT hold (the finding):**
- The hypothesis "checkout keeps succeeding during the whole drain" is **FALSE** here:
  8.88 % client-side errors, well past the 1 % error budget, with a ~1-min window where the
  gateway returned no response.
- **Root cause — capacity, not design.** The three `Standard_B2s` nodes (2 vCPU each) sit at
  **82–99 % CPU-requests** in steady state (3-broker Kafka + 4 CNPG clusters dominate). Draining
  one node forces its pods onto two already-full nodes → **CPU starvation** → probe timeouts
  (`context deadline exceeded`) cascade across catalog, kafka, orders, payments, the CNPG
  operator and Prometheus → BackOff/crashloops → the checkout degrades. The USE dashboard shows
  the CPU-throttling spike and the container-restart step; the RED dashboard shows the
  success-rate dip and error spike (`ce-3-images/`).
- **Aggravators:** Traefik runs a **single replica** (a gateway SPOF); and the CPU HPAs scaled
  *up* on the starvation-induced CPU (a false signal — the truer signal is Kafka lag, ADR 0023),
  adding replicas the cluster could not place (Pending), deepening the pressure. Recovery after
  uncordon was not instant for the same reason.

## Dashboard captures

Native Grafana, drain window (renders in CEST = UTC+2, so ~19:32–19:37):
- **USE** — [`ce-3-images/ce3-use-infrastructure.png`](ce-3-images/ce3-use-infrastructure.png):
  the CPU-saturation (throttled-period) spike and the container-restarts step — the starvation
  cascade, visible.
- **RED** — [`ce-3-images/ce3-red-money-path.png`](ce-3-images/ce3-red-money-path.png): the
  checkout success-rate dip and 5xx spike during the window (the 1-hour success stat dilutes it;
  the k6 client-side 8.88 % is the sharp measure).

## Conclusion

> **Draft — pending team ratification (ADR 0019).**

The hypothesis **did not hold**, and that is the result worth having. The *resilience patterns*
all worked — hard spread kept a replica of every service alive, PDBs protected the databases,
CNPG failed the primary over with RPO 0, and not a single order was lost or double-processed.
But the *cluster* cannot absorb the loss of a node: at 82–99 % CPU-requests across three 2-vCPU
nodes, draining one starves the other two and the checkout degrades past its error budget for
the duration. This is a **sizing limit (ADR 0001), not an application-resilience defect** — the
same code on a cluster with N+1 headroom would ride the drain out (the availability is already
guaranteed *structurally* by the hard spread; it fails only because the replacement pods have
nowhere with spare CPU to run).

**Recommendations (for ADR 0001 / 0023):**
1. **N+1 capacity for voluntary disruptions:** a 4th node (or a temporary scale-up) before any
   node drain / upgrade / the live demo — the cluster needs one node of headroom to reschedule.
2. **Traefik ≥ 2 replicas** with its own hard spread — remove the gateway single-point-of-failure
   this run exposed.
3. **A real node upgrade runbook:** cordon → planned CNPG switchover of any primary on the node →
   drain with the PDBs → uncordon; never drain a saturated node cold.
4. Revisit CPU-based HPA (ADR 0023 already flags it): under starvation it scales the wrong way.

Re-running CE-3 after a 4th node is added would convert this FAIL into the PASS the design
predicts — a clean "found the limit → fixed the sizing → proven" follow-up for the demo.
