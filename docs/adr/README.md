# Architecture Decision Records

Team-owned architecture decisions for EuroTransit. Each ADR captures one decision,
its context, the alternatives, and its consequences. ADRs are referenced from the
capstone design docs and justify the platform bootstrap in `platform/`.

## Conventions

- One file per decision: `NNNN-kebab-title.md` (zero-padded, e.g. `0001-aks-cluster-sizing-and-budget.md`).
- Start from [`template.md`](template.md).
- Status lifecycle: **Proposed** → **Accepted** (after team ratification) → **Superseded** (link the successor).
- ADRs are immutable once Accepted — to change a decision, write a new ADR that supersedes the old one.
- Decisions drafted with agent assistance must include a **Verification & ownership** section per the agentic-coding policy.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [0001](0001-aks-cluster-sizing-and-budget.md) | AKS Cluster Sizing and Budget Strategy | Proposed | 2026-06-29 |
| [0002](0002-graceful-shutdown-and-probes.md) | Graceful Shutdown and Probe Configuration | Proposed | 2026-06-29 |
| [0003](0003-argocd-sync-options-for-operator-crds.md) | Argo CD Sync Options for Operator-CRD Dependencies | Proposed | 2026-07-01 |
| [0004](0004-operator-version-pinning.md) | Operator Version Pinning | Proposed | 2026-07-01 |
| [0005](0005-node-sizing-under-vcpu-quota.md) | Node Sizing under Regional vCPU Quota (3× B2s_v2) | Proposed | 2026-07-08 |
| [0006](0006-drop-k3d-azure-only.md) | Drop Local k3d; Run Everything on Azure (AKS) | Proposed | 2026-07-09 |
| [0007](0007-gitops-writeback-github-app.md) | Cross-repo GitOps Write-back via a GitHub App (not a PAT) | Proposed | 2026-07-09 |
| [0008](0008-single-helm-chart.md) | Single Helm Chart for All Five Services | Proposed | 2026-07-09 |
| [0009](0009-trunk-based-single-stack.md) | Trunk-based Delivery; One Stack, No Staging | Proposed | 2026-07-09 |
| [0010](0010-acr-access-oidc-managed-identity.md) | ACR Access via GitHub OIDC + Managed Identity | Proposed | 2026-07-09 |
| [0011](0011-scoped-appprojects.md) | Scoped AppProjects (platform + eurotransit) | Proposed | 2026-07-09 |
| [0012](0012-traefik-ingressroute-over-ingress.md) | Traefik IngressRoute over native Ingress | Proposed | 2026-07-09 |
| [0013](0013-config-ci-validation.md) | Config-repo CI Validation: Policy-as-code + Secret Scanning | Proposed | 2026-07-09 |
| [0014](0014-strimzi-v1-api-migration.md) | Migrate Kafka CRs to the `kafka.strimzi.io/v1` API | Proposed | 2026-07-10 |
| [0015](0015-argocd-github-webhook.md) | Argo CD GitHub webhook via a patch-mode SealedSecret | Proposed | 2026-07-11 |
| [0016](0016-config-repo-branch-protection-ci-bypass.md) | Config-repo Branch Protection with a CI-app Bypass Actor | Proposed | 2026-07-10 |
| [0017](0017-chaos-mesh-installation.md) | Chaos Mesh installation and experiment execution model | Proposed | 2026-07-11 |
| [0019](0019-single-approval-review-policy.md) | Single-approval review policy (CODEOWNERS flattened) | Accepted | 2026-07-11 |
