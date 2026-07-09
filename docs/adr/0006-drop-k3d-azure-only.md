# ADR 0006 — Drop local k3d; run everything on Azure (AKS)

- **Status:** Proposed
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** platform, gitops, cost, delivery
- **Supersedes / Superseded by:** Partially supersedes [ADR 0004](0004-operator-version-pinning-and-cluster-parity.md) (retires the k3d↔AKS parity requirement, point 2); revises the "develop on local k3d" cost strategy in [ADR 0001](0001-aks-cluster-sizing-and-budget.md) and [ADR 0005](0005-node-sizing-under-vcpu-quota.md).

---

## Context

The original delivery model (ADR 0001, 0004, 0005) kept **two** control planes: a local
**k3d** cluster for zero-cost iteration and the graded **AKS `aks-eurotransit-g01`** cluster
for the public DNS / Let's-Encrypt path and the chaos demo. ADR 0004 then required k3d to be
pinned at **exact k8s parity** with AKS (1.34) so "works on k3d" would mean "works on AKS".

In practice the parity model cost more than it saved:

- **Parity is fragile and never complete.** Cert issuance (HTTP-01) needs a public LB, so it
  was never k3d-testable; NetworkPolicy is a no-op under k3d's default Flannel; storage
  classes, LB behaviour and Azure CNI differ. The things most likely to break on AKS were
  precisely the ones k3d could not exercise.
- **Maintenance tax.** Every operator/k8s bump became a coupled edit across both clusters
  (see the four-edit Strimzi bump in ADR 0004), plus a k3d-specific manual bootstrap path in
  the `Justfile` that duplicated what Argo CD already does via GitOps.
- **AKS is now live and the single source of truth.** The north-south path (Traefik, real
  Let's-Encrypt cert, Argo CD UI + SSO) is deployed and reconciling from `main`. The GitOps
  loop — not a local cluster — is where we validate changes.

The remaining offline safety net (`helm lint`, `helm template`, kubeconform schema checks)
does not need a cluster at all, so the CRD/render class of problems is still caught before
merge without k3d.

## Decision

1. **Remove k3d entirely.** One Kubernetes environment: **AKS**. Deleted `k3d-config.yaml`,
   the PowerShell bootstrap scripts, and every k3d-specific `Justfile` recipe
   (`up`, `down`, `bootstrap`, `bootstrap-branch`, `bootstrap-manual`, `install-operator`,
   `install-cnpg`, `deploy-topics`, `deploy-postgres`, `helm-dry-run`).

2. **The manual (non-GitOps) bootstrap path is retired.** Operators and CRs are installed
   and reconciled **only** by Argo CD from Git. There is no imperative `helm install` /
   `kubectl apply` path for the platform anymore.

3. **Pre-merge validation is offline-only.** `just helm-verify` (lint + template render +
   no plaintext secrets + no public services) and `just helm-schema` (kubeconform) are the
   gates. Cluster validation happens on AKS via the GitOps loop, optionally on a feature
   branch with `just aks-bootstrap <branch>`.

4. **The operator/k8s pins from ADR 0004 stand unchanged** (Strimzi 1.1.0, CNPG 0.29.0,
   cert-manager, all supporting k8s 1.34). Only the requirement to *mirror* those pins on a
   local k3d cluster is retired.

## Alternatives considered

- **Keep k3d for local iteration.** Rejected — the maintenance and parity tax outweighs the
  benefit now that AKS is live and the offline gates catch the render/CRD problems k3d was
  mainly used for.
- **Swap k3d for `kind` or Minikube.** Rejected — same parity gaps (LB, CNI, cert issuance,
  storage) and the same two-environment maintenance cost, just a different local runtime.
- **Keep the manual bootstrap path as an offline escape hatch.** Rejected — it duplicates the
  GitOps path, and running it against the Argo-managed cluster fights `selfHeal`/`prune`
  (one path per cluster). GitOps is the only supported path.

## Consequences

**Easier:**
- One environment, one bootstrap path (GitOps), one place decisions land — no k3d↔AKS drift.
- Operator/k8s bumps are a single edit in the platform Applications, not a coupled pair.
- Smaller, simpler `Justfile` and repo (no k3d config, PS scripts, or manual recipes).

**Harder / risks:**
- **No free local cluster.** Any cluster-level validation now consumes AKS (cost) — mitigate
  with `az aks stop` / scale-to-1 when idle (ADR 0001) and by relying on the offline gates
  for most changes.
- **Feedback loop needs a pushed branch.** Argo pulls from the remote, so cluster testing
  requires pushing a branch and `just aks-bootstrap <branch>` rather than a local spin-up.
- **The offline gates must stay trustworthy.** With no k3d smoke test, `helm-verify` +
  `helm-schema` are the only pre-merge guard — keep them green and expand coverage if a class
  of AKS-only failure slips through.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] Confirm the team accepts losing a zero-cost local cluster in exchange for a single
      Azure-only environment (cost vs. simplicity trade-off is a team call).
- [ ] Confirm `just helm-verify` + `just helm-schema` are sufficient as the sole pre-merge
      gate, or add coverage if not.
- [ ] Confirm the AKS cost-control discipline (`az aks stop` / scale-down when idle) is
      workable for the remaining schedule.
- [ ] Mark ADR 0004's parity clause (point 2) as superseded by this ADR once ratified.

## References

- [ADR 0001 — AKS Cluster Sizing and Budget Strategy](0001-aks-cluster-sizing-and-budget.md)
- [ADR 0004 — Operator Version Pinning and Dev/Prod Cluster Parity](0004-operator-version-pinning-and-cluster-parity.md)
- [ADR 0005 — Node Sizing under Regional vCPU Quota](0005-node-sizing-under-vcpu-quota.md)
- `docs/agent-log.md` — entries #8/#9 record the k3d version-pinning bugs that motivated the parity tax
