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
| [0004](0004-operator-version-pinning-and-cluster-parity.md) | Operator Version Pinning and Dev/Prod Cluster Parity | Proposed | 2026-07-01 |
