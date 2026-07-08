# Delivery model: branch-based promotion (staging → main)

EuroTransit promotes changes through a long-lived **`staging` branch**, not a
separate running environment. There is **one** deployed stack (`eurotransit`, ns
`eurotransit`, `eurotransit.vojtechn.dev`), reconciled by `root-app` from `main`.

```
root-app (main) → workloads → eurotransit → ns eurotransit → eurotransit.vojtechn.dev
```

## Why branch-only (no separate `eurotransit-staging` env)

A parallel staging *namespace* was built and evaluated (see git history:
`apps/eurotransit-staging.yaml`, `values-staging.yaml`), then **dropped**:

- It isn't graded — the capstone requires GitOps + **canary/blue-green**, and
  progressive delivery happens *within* one environment (traffic-split between
  versions), not via a second environment.
- There's no real production traffic to protect; "prod" is the demo cluster.
- Two full stacks are tight on the 6-vCPU pool (ADR 0005).

The `staging` **branch** is kept — it's the cheap, valuable part: an integration +
promotion lane that gives a "validated before main" gate without a second stack.

## The promotion flow

```
feature/EM-xx  ──►  staging  ──►  main
   (build)        (integrate,      (prod;
                   validate on      root-app
                   the cluster)     reconciles)
```

**Test a change:**
```bash
git switch staging
git merge --no-ff feature/EM-xx-my-change     # or cherry-pick
git push origin staging
```
Validate against the running cluster (there's one env, so point it at `staging`
only when you want to test unmerged work; normally it tracks `main`).

**Promote to prod:** open a PR **`staging → main`**, review, merge. `root-app`
reconciles `main` → the live stack updates. Rollback = `git revert` on `main`.

**Rules:**
- Never edit `main` directly — changes reach it only via a `staging → main` PR
  (enforced by branch protection + the `enforce-promotion` CI check).
- Never hand-edit the cluster — push to Git and let Argo converge (self-heal on).

## Image promotion (one artifact, not two)

CI builds **one** immutable image per commit (Git-SHA tag), pushes to ACR **once**,
and writes that tag into `values.yaml`. Promotion moves the *same* tag from
`staging` to `main` via the PR — never a separate "staging build" and "prod build".
That keeps "what you tested" byte-identical to "what you ship" and makes rollbacks
exact.

## DNS & TLS (for reference)

- One wildcard record `*.eurotransit.vojtechn.dev → <Traefik LB IP>` covers
  `argocd.` (and any future host). The prod apex `eurotransit.vojtechn.dev` has its
  own record.
- Prod uses `letsencrypt-prod` (trusted). Each host gets its own HTTP-01 cert.
