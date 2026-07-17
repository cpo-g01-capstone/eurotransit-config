# ADR 0007 — Cross-repo GitOps write-back via a GitHub App (not a PAT)

- **Status:** Accepted (team ratification 2026-07-17 — in daily use: CI-bot write-back on every main build)
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** gitops, ci, security
- **Supersedes / Superseded by:** —

---

## Context

The delivery loop is pull-based: the **app repo** (`eurotransit-app`) CI builds and
pushes immutable images, then **writes the new image tag into the config repo**
(`eurotransit-config` `values.yaml`); Argo CD reconciles from there. That write is a
**cross-repo push** — CI in one repo committing to another — which needs a credential
GitHub's built-in `GITHUB_TOKEN` cannot provide (it is scoped to the running repo only).

The `update-gitops` job originally referenced `secrets.CONFIG_REPO_PAT`. Two ways to
supply that credential:

- **Fine-grained PAT** — a token minted from **one person's** account, granted
  Contents: read+write on `eurotransit-config`, stored as an app-repo Actions secret.
- **GitHub App** — an org-owned identity installed on `eurotransit-config` with
  Contents: write; CI mints a **short-lived installation token** per run via
  `actions/create-github-app-token`.

This is the only credential in the pipeline that can write to the source of truth, so
its ownership and blast radius matter.

## Decision

Use a **GitHub App** for the config-repo write-back. Concretely:

1. A GitHub App (**"EuroTransit GitOps Writeback"**) is created at the **org**
   (`cpo-g01-capstone`) level with **Repository permission → Contents: Read and write**
   and **no** other permissions.
2. It is **installed on `eurotransit-config` only** (not org-wide, not on the app repo).
3. The app repo holds two Actions secrets — `CONFIG_REPO_APP_ID` and
   `CONFIG_REPO_APP_PRIVATE_KEY` — and the `update-gitops` job mints a per-run
   installation token scoped to `repositories: eurotransit-config`.
4. Commits are attributed to the App's bot user (`<app-slug>[bot]`), so the audit trail
   shows the App — not a person — writing to the source of truth.
5. The `CONFIG_REPO_PAT` path is retired.

The rest of the CI invariants are unchanged: **no cluster credentials in CI**, the write
targets only Git, and Argo CD does the deploy (see [ADR 0006](0006-drop-k3d-azure-only.md),
`.agent/agents/delivery-owner.md`).

## Alternatives considered

- **Fine-grained PAT (rejected).** Simplest to set up, but the token is tied to one
  person's account: if that person leaves the org or loses access, CI write-back dies
  silently. It also carries a hard expiry that must be babysat (CI breaks the day it
  lapses), and on an org fine-grained PATs often need separate owner approval.
- **`GITHUB_TOKEN` with cross-repo scope (not possible).** The built-in token cannot be
  granted write to a different repo — this is exactly the gap being filled.
- **Deploy key on the config repo (rejected).** An SSH deploy key would work for push but
  is per-repo, not centrally manageable, offers no fine-grained permission model, and no
  short-lived-token story.

## Consequences

**Easier / better:**
- **Org-owned, not person-owned** — survives any teammate leaving; no personal-account coupling.
- **Short-lived tokens** — the installation token expires (~1h) and is minted per run;
  nothing long-lived to leak. No expiry to babysit.
- **Least privilege, auditable** — Contents: write on exactly one repo; commits attributed
  to the App's bot identity.

**Harder / risks:**
- **More setup than a PAT** — creating the App, storing a private key, installing it on the
  config repo (documented in `infra/gitops-writeback-app/README.md`).
- **Private key is a real secret** — unlike the OIDC/ACR flow (EM-41), the App uses a
  private key stored as `CONFIG_REPO_APP_PRIVATE_KEY`. It must be a GitHub **Actions
  secret** (never committed) and rotated if leaked.
- **Two more secrets to manage** on the app repo (`CONFIG_REPO_APP_ID`,
  `CONFIG_REPO_APP_PRIVATE_KEY`).

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] Confirm the extra setup vs. a PAT is worth the org-ownership + no-expiry benefit for
      the remaining project timeline (this is the team's call).
- [ ] Create the App with **Contents: write only** and install it on `eurotransit-config`
      **only** — verify no broader scope was granted.
- [ ] Confirm `CONFIG_REPO_APP_PRIVATE_KEY` is stored as an Actions secret and the raw key
      never lands in Git.
- [ ] Run the app-repo CI on `main` once and confirm the `update-gitops` job commits as
      `<app-slug>[bot]` and Argo CD reconciles the tag bump.

## References

- Setup runbook: `infra/gitops-writeback-app/README.md`
- App-repo workflow: `eurotransit-app/.github/workflows/ci.yml` (`update-gitops` job)
- [ADR 0006 — Drop Local k3d; Run Everything on Azure](0006-drop-k3d-azure-only.md)
- `.agent/agents/delivery-owner.md` — CI never holds cluster credentials; writes go to Git
- [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
