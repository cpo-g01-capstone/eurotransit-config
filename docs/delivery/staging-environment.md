# Delivery model: trunk-based, GitOps to `main`

EuroTransit deploys **one** stack (`eurotransit`, ns `eurotransit`,
`eurotransit.vojtechn.dev`), reconciled by `root-app` from **`main`**. There is no
separate staging environment and no long-lived staging branch — changes flow from
short-lived feature branches straight to `main` via reviewed PRs.

```
feature/EM-xx ──PR──► main ──► root-app (Argo CD) ──► cluster
```

## Why this shape

- A parallel staging *namespace* and a long-lived `staging` *branch* were both
  built and evaluated (see git history), then dropped: neither is graded, there's
  no real production traffic to protect ("prod" is the demo cluster), and two
  stacks are tight on the 6-vCPU pool (ADR 0005). The safety they'd add is covered
  by PR review + CI on the feature branch.

## The flow

**Change:** branch `feature/EM-xx`, open a PR to `main`, CI validates
(`helm-verify` etc.), review, merge. `root-app` reconciles `main` → the live stack
updates within seconds (webhook) / ~3 min (poll).

**Rollback:** `git revert` the bad commit on `main` and push — Argo converges back.
Never hand-edit the cluster (self-heal is on) and never `kubectl rollout undo`.

**Test unmerged work on the cluster (optional):** point Argo at the branch with
`just aks-bootstrap <branch>` before merging — but the normal path is PR → `main`.

## Image promotion (one artifact)

CI builds **one** immutable image per commit (Git-SHA tag), pushes to ACR once, and
writes that tag into `values.yaml`. There is no separate "staging build" — the
image that CI validated is byte-identical to what `main` ships, which keeps
rollbacks exact.

## DNS & TLS (for reference)

- Wildcard `*.eurotransit.vojtechn.dev → <Traefik LB IP>` covers `argocd.` and any
  future host; the apex `eurotransit.vojtechn.dev` has its own record.
- Prod uses `letsencrypt-prod` (trusted); each host gets its own HTTP-01 cert.
