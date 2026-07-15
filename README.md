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
bootstrap/            — Argo CD install + the root app-of-apps (the entry point of the whole tree)
apps/                 — Argo CD Applications for the workloads (eurotransit, kafka, data infra)
deploy/charts/        — the single Helm chart reconciled by Argo CD; CI bumps image tags in values.yaml
platform/             — platform component configurations (installed once per cluster)
kafka/                — Strimzi Kafka CR, KafkaTopic CRs, KafkaUser CRs
postgres/             — CloudNativePG Cluster CRs (one per stateful service)
infra/                — setup docs for out-of-cluster infrastructure (ACR OIDC, GitOps write-back App)
scripts/              — helper scripts used by the Justfile
docs/                 — team documentation, ADRs, DoD, design, chaos reports, postmortem
.agent/               — structured context for coding agents and team members
.claude/              — Claude Code permission rules
.github/              — CODEOWNERS + the validate.yml PR gate
```

## Delivery decisions

[`DELIVERY.md`](DELIVERY.md) is the overview of every delivery/platform decision (with
trade-offs), indexing the [ADRs](docs/adr/) and [runbooks](docs/delivery/).

## How to work here

All changes to `main` go through a pull request with at least one approval.
See `.github/CODEOWNERS` for path-based reviewers.

Every PR is validated by [`.github/workflows/validate.yml`](.github/workflows/validate.yml) —
helm lint/template, kubeconform schema checks, **kube-linter** policy-as-code, and **gitleaks**
secret scanning (ADR 0013). Run the same offline gate locally before pushing:

```bash
just helm-verify      # lint + template + no plaintext secrets + no public services
just helm-schema      # kubeconform schema validation (needs kubeconform)
just install-hooks    # once: opt-in pre-commit secret guard (needs gitleaks)
```

**Do not** run `helm upgrade` or `kubectl apply` against the live cluster directly.
Change `deploy/charts/eurotransit/values.yaml` or templates → open PR → merge → Argo CD reconciles.

**Rollback:** `git revert <commit>` on the bad values.yaml commit → push → Argo CD self-heals.

## Demos and links

| Deliverable | Link |
|-------------|------|
| Recorded demo (~5 min) | *(to be committed)* |
| Live presentation | *(to be scheduled)* |
