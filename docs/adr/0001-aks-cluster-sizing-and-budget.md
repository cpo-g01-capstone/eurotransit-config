# ADR 0001 — AKS Cluster Sizing and Budget Strategy

- **Status:** Proposed (awaiting team ratification)
- **Date:** 2026-06-29
- **Deciders:** _<add team members>_
- **Context tags:** platform, cost, AKS, capstone
- **Supersedes / Superseded by:** node-sizing amended by [ADR 0005](0005-node-sizing-under-vcpu-quota.md) — `3× B4als_v2` was infeasible under the Poland Central vCPU quota; the cluster runs `3× B2s_v2`. Budget/naming/RBAC/stop-scale discipline below still apply.

---

## Context

The EuroTransit capstone runs a full platform stack *once per cluster* — Traefik,
cert-manager, CloudNativePG, Strimzi/Kafka, Sealed Secrets, Argo CD,
kube-prometheus-stack, and Chaos Mesh — plus five JVM (Kotlin/Spring Boot) services.
We must host this on a single shared AKS cluster per group, funded by one teammate's
Azure-for-Students credit (USD 100, no financially backed SLA needed).

Two constraints shape the decision:

1. **Memory footprint.** The resident platform set is heavy (Prometheus stack ~2–3 GB,
   Argo CD ~1 GB, Kafka ~1 GB/broker, Postgres primary+standby ~1 GB, operators ~1.5 GB,
   five JVM services ~2.5–4 GB, AKS system pods ~0.5–1 GB/node). Realistic resident usage
   is ~10–14 GB. The 4 GB `B2als_v2` node used in Lab02/Lab03 is insufficient for the
   full system.
2. **Multi-node requirement.** Two mandatory chaos experiments require more than one node:
   experiment #3 ("Node / AZ-style disruption: do PDBs and topology spread keep the
   critical path available?") and the anti-affinity spread of Kafka (3 brokers) and the
   CloudNativePG primary/standby. A single large node cannot demonstrate
   PodDisruptionBudgets, topology spread, or node drain.

## Decision

- **Service:** Azure Kubernetes Service (AKS), **Free** control-plane tier (USD 0; no SLA).
- **Node pool:** **3 × `Standard_B4als_v2`** (4 vCPU / 8 GB each) — System mode,
  availability zones deselected (Azure-for-Students restriction).
  → 12 vCPU / 24 GB total, ~18 GB schedulable after AKS system reservation.
- **Registry:** 1 × Azure Container Registry (ACR), **Basic** tier (free on the student plan), attached to the cluster.
- **Ingress:** 1 × Standard Load Balancer + 1 public IP for the Traefik entrypoint (course-managed DNS maps to the Azure FQDN).
- **Storage:** Small managed disks for PVCs only — Prometheus retention kept low (~10–20 GB),
  Kafka and Postgres volumes 5–10 GB each.
- **Cost control:** The cluster is **stopped when idle** (`az aks stop` / `az aks start`).
  Day-to-day cloud work runs on a **1-node** pool; we **`az aks scale` to 3 nodes only for
  integration testing, the recorded demo, and the live presentation.** Where possible,
  development happens on a **local cluster** (kind/k3d) to preserve credit; AKS is reserved
  for the public DNS/Let's-Encrypt path and the multi-node chaos demo.

## Technical parameters
- **AKS region:** (Europe) Poland Central
- **Kubernetes version:** 1.34.8
- **Node pool:** name (system), VM (Standard_B4als_v2, 4 vCPUs, 8 GiB memory) x 1 (for now)

### Resource naming & tagging

All Azure resources follow the Cloud Adoption Framework pattern `<type>-<workload>-<id>`,
kept short for a single-cluster student project. `<id>` is the course group number
(**`g01`** — confirm against the assigned group). `<region>` is pinned once and reused
(see the region-risk note under Consequences).

| Resource | Name | Notes / constraints |
|---|---|---|
| Resource group | `rg-eurotransit-g01` | Everything lives here. ≤90 chars. |
| AKS cluster | `aks-eurotransit-g01` | ≤63 chars, alphanumeric + hyphen. |
| AKS DNS prefix | `eurotransit-g01` | Forms the API server FQDN. |
| Node pool (System mode) | `system` | Agent-pool names are strict: **1–12 chars, lowercase alphanumeric only, must start with a letter — no hyphens**. A later user pool would be `apps`/`userpool`. |
| Infrastructure resource group | `MC_rg-eurotransit-g01_aks-eurotransit-g01_polandcentral` | Azure default |
| Container registry | `acreurotransitg01` | Login server: `acreurotransitg01.azurecr.io` |
| Container registry resource group | `rg-acreurotransitg01`| rg_ + container registry name |
| Public IP (Traefik) | `pip-eurotransit-g01-traefik` | The single north-south entrypoint. |
| Managed identity | `id-eurotransit-g01` | Cluster/kubelet identity for ACR pull. |
| Log Analytics workspace | `log-eurotransit-g01` | Only if Container Insights is enabled (consumes credit — optional). |

The ACR name maps into the Helm chart via `global.imageRegistry: "acreurotransitg01.azurecr.io"`
in the AKS values override (local k3d leaves it empty).

**Region:** (Europe) Poland Central

**Tags:** every resource carries the following for cost tracking and cleanup:

```
project=eurotransit  group=g01  env=capstone  owner=<azure-credit-holder>  managed-by=manual
```

### Access & RBAC

The Azure-for-Students credit holder owns the subscription. Teammates are granted access
via Azure RBAC role assignments rather than sharing credentials.

| Principal | Role | Scope | Why |
|---|---|---|---|
| Credit holder | **Owner** | subscription | Provisions resources and manages access; only they can grant roles. |
| Teammates | **Contributor** | subscription | Manage resources and use the cluster, but cannot change access assignments. |

**Scope note — ACR is in a separate resource group.** Because the registry lives in
`rg-acreurotransitg01` (not `rg-eurotransit-g01`), a single resource-group-scoped
assignment would *not* cover it. We therefore assign at the **subscription scope** (one
assignment per teammate covers both resource groups) for this single shared subscription.
If finer-grained scoping is wanted later, assign Contributor on both `rg-eurotransit-g01`
and `rg-acreurotransitg01` instead.

**Granting access (portal):** resource scope → **Access control (IAM)** → **+ Add → Add
role assignment** → pick role → **Members** → select teammate → **Review + assign**.

**Cluster (kubectl) access:** Contributor includes permission to run
`az aks get-credentials --resource-group rg-eurotransit-g01 --name aks-eurotransit-g01`.
Day-to-day cluster changes go through Argo CD (GitOps); `kubectl` is for inspection and
debugging only.

**Caveats:**
- **Tenant.** Teammates in the same university Entra tenant appear in member search
  directly; external accounts must first be invited as guest users (Entra ID → Users →
  Invite external user), which some student tenants restrict.
- **Billing.** All teammate activity consumes the credit holder's USD 100 — reinforces the
  start/stop discipline above. Agree as a team who runs the cluster when.

## Alternatives considered

| Node size | vCPU / RAM | ~Price/hr | 3 nodes 24/7 | Verdict |
|---|---|---|---|---|
| `B2als_v2` | 2 / 4 GB | ~$0.038 | ~$83/mo | Rejected — too little RAM for the full stack (Lab02/03 size) |
| `B2s_v2` | 2 / 8 GB | ~$0.083 | ~$182/mo | Fallback if `B4als_v2` is unavailable in-region; CPU tight for 5 JVMs + Prometheus |
| **`B4als_v2`** | **4 / 8 GB** | **~$0.087** | **~$190/mo** | **Chosen** — best RAM-and-CPU fit per credit |
| `B4s_v2` | 4 / 16 GB | ~$0.166 | ~$363/mo | Comfortable but burns credit too fast |

Single large node (1 × 16–32 GB): rejected — cannot demonstrate node disruption,
PDBs, or topology spread (capstone chaos experiment #3).

## Consequences

**Positive**
- ~18 GB schedulable comfortably hosts the platform + services with headroom for
  canary/blue-green (two versions side by side).
- Three nodes satisfy the resilience/chaos requirements directly.
- AKS Free tier + ACR Basic keep fixed costs at ~$0; credit is spent only on running compute.

**Negative / risks**
- **`az aks stop` halts VM billing but disks and the public IP keep charging** — small but
  continuous. Mitigated by keeping PVCs small.
- At ~$0.26/hr for the 3-node pool, 24/7 operation would exhaust USD 100 in ~16 days.
  **The budget only works with disciplined start/stop.** Estimated burn at ~4 active
  hours/day for a month ≈ ~$31 compute + ~$10 disks/IP ≈ ~$41.
- Region risk: `B4als_v2` availability varies; if not offered in our assigned region we
  fall back to `B2s_v2` (per the table above).

## Verification & ownership (agentic-coding policy)

This sizing was drafted with agent assistance and **must be verified and owned by the team**
before ratification:

- [ ] Confirm `B4als_v2` is offered in our assigned Azure-for-Students region (else use `B2s_v2`).
- [ ] Confirm the group id (`g01`) and pin the region; verify the ACR name `acreurotransitg01`
      is globally available (else append a suffix) before provisioning.
- [ ] After first full deploy, compare actual allocatable/used memory against the ~10–14 GB
      estimate; if the pool is too tight (e.g., forced down to one Kafka broker), record the
      correction in `docs/agent-log.md`.
- [ ] Validate that `az aks stop`/`start` and `az aks scale` behave as assumed and that
      stopped-cluster residual cost (disks + IP) is acceptable.
- [ ] Grant each teammate **Contributor** at subscription scope; confirm they can run
      `az aks get-credentials` and (if external) that guest invites are permitted in the tenant.

## References

- Capstone spec — platform components installed once per cluster; two-repository model.
- Lab02 Prerequisites — AKS creation, node pool sizing, ACR, `az aks stop/start` cost hygiene.
- Lab03 — Traefik single public entrypoint, cert-manager, CloudNativePG.
- Azure VM pricing (pay-as-you-go, verify for current region at decision time).
