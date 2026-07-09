# EuroTransit — Configuration Repository

This repository is the **source of truth for what should be running** in the EuroTransit cluster.
Argo CD reads this repository and reconciles the cluster to match.

## Ownership boundary

| Question | Repository |
|----------|-----------|
| What code was built and tested? | application-repo |
| Which immutable images are available? | Azure Container Registry |
| **What should be running?** | **this repository** |
| Does the cluster match the declaration? | Argo CD (reads this repo) |
| How is the rollout executed? | Kubernetes controllers |

## Team roles

| GitHub | Role |
|--------|------|
| @vojtech-n | Delivery owner — GitOps, Argo CD, Kafka wiring, progressive delivery |
| @giova95 | Resilience owner — circuit breakers, chaos experiments, probes, PDBs |
| @Lollegro | Domain & async owner — service decomposition, coroutines, Kafka pipeline |
| @marcodonatucci | Observability & verification + Project Manager |
| @MauroC0l | Data & consistency — CloudNativePG, inventory model, idempotency |

## Repository structure

```
.agent/               — structured context for coding agents and team members
.claude/              — Claude Code permission rules
.github/              — CODEOWNERS
deploy/charts/        — Helm chart reconciled by Argo CD
platform/             — platform component configurations (installed once per cluster)
docs/                 — team documentation, DoD, chaos reports, postmortem
```

## Delivery decisions

[`DELIVERY.md`](DELIVERY.md) is the overview of every delivery/platform decision (with
trade-offs), indexing the [ADRs](docs/adr/) and [runbooks](docs/delivery/).

## How to work here

All changes to `main` go through a pull request with at least one approval.
See `.github/CODEOWNERS` for path-based reviewers.

**Do not** run `helm upgrade` or `kubectl apply` against the live cluster directly.
Change `deploy/charts/eurotransit/values.yaml` or templates → open PR → merge → Argo CD reconciles.

**Rollback:** `git revert <commit>` on the bad values.yaml commit → push → Argo CD self-heals.

## Demos and links

| Deliverable | Link |
|-------------|------|
| Recorded demo (~5 min) | *(to be committed)* |
| Live presentation | *(to be scheduled)* |
