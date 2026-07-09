# EM-39 — Argo CD GitHub SSO + RBAC

Replaces the shared local `admin` login with **GitHub SSO** (via Dex) and RBAC on
the self-managed Argo CD. Login is restricted to the `cpo-g01-capstone` org; every
org member gets Argo **admin** (team decision — everyone operates the system).

## What's in Git (reconciled automatically)

| File | Role |
|---|---|
| `bootstrap/install/patch-argocd-cm.yaml` | `url` + Dex GitHub connector (org-restricted) |
| `bootstrap/install/patch-rbac-cm.yaml` | `policy.default: role:admin` |
| `bootstrap/apps/argocd.yaml` | `ignoreDifferences` on `argocd-secret` `/data` (prevents self-heal wiping `server.secretkey`/`admin.password`) |
| `platform/argocd/secrets/argocd-github-oauth.sealed.yaml` | **you create this** — sealed OAuth clientID + clientSecret |

The Dex config references the OAuth creds from a *separate* secret
(`$argocd-github-oauth:clientID/clientSecret`), labelled `app.kubernetes.io/part-of:
argocd` so Argo can read it — keeping them out of the sensitive core `argocd-secret`.

## Step 1 — create the GitHub OAuth App

`cpo-g01-capstone` org → **Settings → Developer settings → OAuth Apps → New OAuth App**:
- **Homepage URL:** `https://argocd.eurotransit.vojtechn.dev`
- **Authorization callback URL:** `https://argocd.eurotransit.vojtechn.dev/api/dex/callback`

Save → copy the **Client ID**, **Generate a client secret**, copy it.

## Step 2 — seal the OAuth creds (never commit plaintext)

Create the plaintext locally (gitignored by `**/secrets/*.yaml`):

```yaml
# platform/argocd/secrets/argocd-github-oauth.yaml   (LOCAL ONLY — do not commit)
apiVersion: v1
kind: Secret
metadata:
  name: argocd-github-oauth
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd     # REQUIRED — lets Argo read it for $-substitution
type: Opaque
stringData:
  clientID: "<GITHUB_OAUTH_CLIENT_ID>"
  clientSecret: "<GITHUB_OAUTH_CLIENT_SECRET>"
```

Seal it (only the `.sealed.yaml` is committed):

```bash
kubeseal --controller-name sealed-secrets --controller-namespace sealed-secrets \
  --scope strict --format yaml \
  < platform/argocd/secrets/argocd-github-oauth.yaml \
  > platform/argocd/secrets/argocd-github-oauth.sealed.yaml
```

## Step 3 — deploy

Merge EM-39 → `main`, push. Then:
- the **argocd self-management** app reconciles `bootstrap/install` → `argocd-cm`
  (Dex config) + `argocd-rbac-cm` are updated;
- the **platform** app applies the SealedSecret → sealed-secrets controller
  materialises `argocd-github-oauth`.

Restart so Dex/API pick up the new config:

```bash
kubectl -n argocd rollout restart deploy/argocd-dex-server deploy/argocd-server
kubectl -n argocd rollout status  deploy/argocd-server --timeout=120s
```

## Step 4 — verify SSO **before** removing anything

Open `https://argocd.eurotransit.vojtechn.dev` → click **LOG IN VIA GITHUB** →
authorize → you should land in as a full admin. If it fails:

```bash
kubectl -n argocd logs deploy/argocd-dex-server | tail        # connector / callback errors
kubectl -n argocd get secret argocd-github-oauth              # exists? (controller decrypted it)
```

Common causes: callback URL mismatch, missing `part-of: argocd` label on the secret,
or not a member of `cpo-g01-capstone`.

## Step 5 — retire the local admin (ONLY after Step 4 succeeds)

```bash
# Remove the plaintext bootstrap password (regenerated only on fresh install):
kubectl -n argocd delete secret argocd-initial-admin-secret
```

Optionally disable the local admin entirely — add to `patch-argocd-cm.yaml`, commit,
let Argo reconcile (a follow-up change, not in EM-39, so there's no lockout window):

```yaml
data:
  admin.enabled: "false"
```

> Keep the local admin as break-glass until you're confident in SSO. `just argocd-ui`
> (port-forward) also bypasses the ingress if SSO or the LB ever breaks.

## RBAC decision (owned)

`policy.default: role:admin` is broader than strict least-privilege, chosen because
all five teammates operate the system and Dex already gates login to the org. To
scope down later: `policy.default: role:readonly` + a GitHub team mapped to admin
via `policy.csv` (`g, cpo-g01-capstone:<team>, role:admin`).
