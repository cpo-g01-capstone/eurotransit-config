# GitOps write-back GitHub App (EM-32)

Setup runbook for the credential the **app-repo** CI uses to push image-tag bumps into
**this** config repo. We use a **GitHub App** installation token rather than a personal
access token — see [ADR 0007](../../docs/adr/0007-gitops-writeback-github-app.md) for why.

> This is one-time account/control-plane setup done in the GitHub UI + `gh` CLI. There is
> nothing to deploy; this folder only documents the decision and the steps so the identity
> is reproducible, not tribal knowledge.

## What the app-repo CI expects

The `update-gitops` job in `eurotransit-app/.github/workflows/ci.yml` mints a short-lived
token with `actions/create-github-app-token`, scoped to `eurotransit-config`, and uses it
to checkout + commit + push. It reads two secrets on the **app repo**:

| Secret | Value |
|---|---|
| `CONFIG_REPO_APP_ID` | the App's numeric App ID |
| `CONFIG_REPO_APP_PRIVATE_KEY` | the App's `.pem` private key (full contents) |

Until both are set, the job **skips with a warning** — nothing breaks in the meantime.

## Steps (do once, as an org owner)

### 1. Create the App

`https://github.com/organizations/cpo-g01-capstone/settings/apps` → **New GitHub App**

- **Name:** `EuroTransit GitOps Writeback` (the slug becomes the commit author,
  e.g. `eurotransit-gitops-writeback[bot]`)
- **Homepage URL:** the config-repo URL (any valid URL is accepted)
- **Webhook:** **uncheck Active** (we don't receive events)
- **Repository permissions → Contents: Read and write** — and nothing else
  (Metadata: read is added automatically)
- **Where can this App be installed?** Only on this account
- **Create GitHub App**

### 2. Get the App ID and a private key

On the App's settings page:
- Copy the **App ID** (a number).
- **Private keys → Generate a private key** → downloads a `.pem`. Store it safely; GitHub
  keeps only the public half. This is the secret.

### 3. Install the App on the config repo (only)

App settings → **Install App** → install on `cpo-g01-capstone` → **Only select
repositories** → **`eurotransit-config`** → Install. Do **not** install org-wide or on the
app repo.

### 4. Add the two secrets to the app repo

```bash
# App ID
gh secret set CONFIG_REPO_APP_ID -R cpo-g01-capstone/eurotransit-app -b "123456"

# Private key — pass the .pem file contents (not the path)
gh secret set CONFIG_REPO_APP_PRIVATE_KEY -R cpo-g01-capstone/eurotransit-app \
  < ~/Downloads/eurotransit-gitops-writeback.private-key.pem
```

Or via UI: `eurotransit-app` → Settings → Secrets and variables → Actions → New repository
secret. Names must match **exactly**.

### 5. Verify

```bash
gh secret list -R cpo-g01-capstone/eurotransit-app   # both names present (values hidden)
```

Then push a change to `eurotransit-app` `main` (or re-run CI). The `update-gitops` job
should commit to this repo as `eurotransit-gitops-writeback[bot]` and Argo CD reconciles
the new tag.

## Security notes

- **Least privilege:** Contents: write on **one** repo. The App cannot touch the app repo,
  other org repos, issues, actions, or settings.
- **Short-lived:** the installation token is minted per run and expires (~1h). Nothing
  long-lived is stored except the private key.
- **The private key is a real secret** — Actions secret only, never committed. Rotate it
  (generate a new key, delete the old) if it is ever exposed.
- **Not a person's token:** ownership stays with the org, so CI write-back survives any one
  teammate leaving — the reason we chose this over a fine-grained PAT (ADR 0007).
