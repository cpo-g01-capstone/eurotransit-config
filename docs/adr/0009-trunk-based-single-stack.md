# ADR 0009 — Trunk-based delivery; one deployed stack, no staging environment

- **Status:** Proposed
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** delivery, gitops, cost
- **Supersedes / Superseded by:** —

---

## Context

Early delivery work stood up a parallel **staging** path — both a staging *namespace*
(`eurotransit-staging`, app-chart-only, 1 replica) and a long-lived `staging` *branch* that
Argo tracked. The intent was a promotion pipeline: `feature → staging → main`. In practice
this created two stacks to keep Synced/Healthy, two branches to reconcile, and real pressure
on the 6-vCPU node budget (ADR 0005), for a system where "production" is itself just the demo
cluster with no live traffic to protect.

## Decision

**One deployed stack, reconciled from `main`, trunk-based.**

- A single stack: namespace `eurotransit`, host `eurotransit.vojtechn.dev`, reconciled by
  `root-app` from **`main`**.
- No staging namespace and no long-lived `staging` branch. Short-lived feature branches flow
  straight to `main` via reviewed PRs:

  ```
  feature/EM-xx ──PR──► main ──► root-app (Argo CD) ──► cluster
  ```

- **One immutable image per commit** (Git-SHA tag) is built once, pushed to ACR once, and its
  tag written into `values.yaml`. There is no separate "staging build" — what CI validated is
  byte-identical to what `main` ships, so rollbacks are exact.
- **Rollback** = `git revert` the bad commit on `main` and push; Argo converges back. Never
  hand-edit the cluster (self-heal is on), never `kubectl rollout undo`.
- **Testing unmerged work on the cluster** (optional) uses `just aks-bootstrap <branch>` to
  point Argo at a feature branch before merging — the normal path is still PR → `main`.

## Alternatives considered

- **Keep staging namespace + branch (the built-then-dropped approach).** Rejected: neither is
  graded, there is no production traffic to protect, and two full stacks do not fit the
  6-vCPU budget (ADR 0005). The safety a staging tier would add is covered by PR review +
  `helm-verify` CI on the feature branch, plus optional on-cluster branch testing.
- **Environment-per-branch (ephemeral preview stacks).** Rejected: attractive but far over
  budget on 6 vCPU and unnecessary for a single-cluster capstone.
- **GitFlow with release branches.** Rejected: heavyweight for a 5-person, one-week-cadence
  team; trunk-based keeps `main` always deployable.

## Consequences

**Easier:**
- One stack and one branch to reason about; `main` is always the live state.
- No image re-build across environments → exact, auditable rollbacks.
- Frees the node budget that a second stack would consume (ADR 0005).

**Harder / risks:**
- **No pre-prod soak.** A bad change reaches the only cluster after merge. Mitigated by
  pre-merge `helm-verify`/`helm-schema`, PR review, and `git revert` rollback with self-heal.
- **`main` must stay green.** Discipline required: no direct pushes; protect `main` (PR +
  CI + 1 review) — tracked as a follow-up.
- On-cluster validation of unmerged work needs a pushed branch (`just aks-bootstrap <branch>`),
  not a local spin-up (consistent with ADR 0006).

## Verification & ownership (agentic-coding policy)

- [ ] Confirm the team accepts no staging tier for the remaining timeline.
- [ ] Enable branch protection on `main` (require PR + `helm-verify` + 1 review).
- [ ] Confirm a `git revert` rollback converges via Argo self-heal at least once.

## References

- `docs/delivery/` runbooks; DELIVERY.md — the delivery overview.
- ADR 0005 — the 6-vCPU budget that a second stack would strain.
- ADR 0006 — Azure-only (no local cluster); branch testing via `just aks-bootstrap`.
