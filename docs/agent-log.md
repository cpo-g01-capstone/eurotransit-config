# Agent log

Records cases where agent-produced artifacts were incorrect, unsafe, or subtly wrong.
**Minimum three entries required before the live presentation. This file is graded.**

All five team members must approve changes to this file (see CODEOWNERS).

Custodian: @marcodonatucci (Observability & Verification).

| # | Date | Area | Summary |
|---|------|------|---------|
| 1 | 2026-06-20 | CI / eurotransit-app | Wrong `paths-filter` globs for service modules |
| 2 | 2026-06-19 | GitOps / eurotransit-config | Placeholder `TODO-TEAM` repo URL in Argo CD Applications |
| 3 | 2026-06-20 | Delivery / docs vs CI | ACR documented but GHCR implemented in workflow |

---

## Case 1 — 2026-06-20 — CI path filters (eurotransit-app)

**What the AI produced:**
The initial `.github/workflows/ci.yml` stub used `dorny/paths-filter` globs such as
`backend/catalog/**`, `backend/orders/**`, etc., matching the *planned* layout in
`justfile` and `CODEOWNERS`, not the layout produced by the EM-13 scaffold
(`backend/catalog-service/**`, `backend/orders-service/**`, …).

**Why it was wrong:**
On a change confined to one service (e.g. only `backend/orders-service/`), the filter
would not match. The `images` job would skip that service entirely: no image rebuild,
no GitOps tag bump, and silent drift between code and cluster.

**How it was caught:**
Manual review while implementing EM-15 (Setup GitHub Actions CI), comparing the
workflow filters against `settings.gradle.kts` and the actual directory tree on `main`.

**How it was corrected:**
Updated every service filter to `backend/<service>-service/**` in
`feature/EM-15-Setup-github-actions-ci` (merged via app PR #2 / follow-up commits).

**Lesson learned:**
Before trusting AI-generated path filters, diff them against `settings.gradle.kts`
`include(...)` lines and a real `find backend -maxdepth 1 -type d`. Scaffold layout
and docs can diverge — the filesystem wins.

---

## Case 2 — 2026-06-19 — Argo CD placeholder repo URL (eurotransit-config)

**What the AI produced:**
Early bootstrap manifests `bootstrap/apps/platform.yaml` and
`bootstrap/apps/workloads.yaml` contained:

```yaml
repoURL: 'https://github.com/TODO-TEAM/eurotransit-config.git' # TO BE CHANGED
```

**Why it was wrong:**
Argo CD would fail to reconcile (or point at a non-existent org) once the app-of-apps
was applied. With `automated.selfHeal: true`, a bad source URL blocks the entire
GitOps loop — no platform components, no workloads.

**How it was caught:**
Kickoff / EM-11 review checklist before merging the platform bootstrap branch.

**How it was corrected:**
Replaced with `https://github.com/cpo-g01-capstone/eurotransit-config.git` before
merge to `main` (EM-11, config PR #6).

**Lesson learned:**
Search every generated manifest for `TODO`, `CHANGEME`, and placeholder hostnames
before the first `kubectl apply` / Argo sync. AI scaffolds often leave these behind.

---

## Case 3 — 2026-06-20 — Image registry mismatch (ACR vs GHCR)

**What the AI produced:**
Two inconsistent artifacts:
- `CLAUDE.md`, `.agent/context.md`, and `delivery-owner.md` describe **Azure Container
  Registry (ACR)** (`<acr>.azurecr.io`, `az` login, push only on `main`).
- The EM-15 CI workflow implementation uses **GHCR** (`REGISTRY: ghcr.io`,
  `docker/login-action` with `GITHUB_TOKEN`, `packages: write`).

**Why it was wrong:**
Subtly dangerous, not a compile failure: a teammate following `CLAUDE.md` would add
ACR secrets and `az acr login` steps (extra credentials, violates least-privilege),
while CI already pushes to GHCR. Conversely, Helm `values.yaml` examples still show
`*.azurecr.io` image repositories that CI will never populate.

**How it was caught:**
Cross-review during EM-15 implementation — workflow comments said GHCR but agent
context files still said ACR.

**How it was corrected:**
CI workflow committed with GHCR as the source of truth (app PR #2). **Follow-up
required:** update `CLAUDE.md`, `delivery-owner.md`, and Helm `values.yaml` image
repository fields to GHCR (or revert CI to ACR if the team chooses Azure — one
registry, documented everywhere).

**Lesson learned:**
Registry choice is a team decision, not something to split across “implementation”
and “docs”. After any AI-generated CI change, grep both repos for the old registry
string and align in the same PR.
