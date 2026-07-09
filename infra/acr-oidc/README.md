# ACR OIDC / pull provisioning (EM-41 — IaC)

One-time Azure control-plane setup that lets **GitHub Actions push images to ACR
without a stored secret** (OIDC), and lets **AKS pull** them. Checked in so the
identity is reproducible and reviewable rather than tribal knowledge (ADR 0006 —
Azure-only, GitOps posture).

> This is **control-plane provisioning**, run once by the subscription Owner. It is
> deliberately **not** part of any CI workflow — the capstone rule is that CI never
> holds Azure/cluster credentials (`CLAUDE.md`, `.agent/agents/delivery-owner.md`).

## Do I need a managed identity + federated credentials?

Almost. The correction: GitHub Actions → Azure OIDC works with **either** a
user-assigned **managed identity** _or_ an **app registration (service principal)**.
Both are just an Azure AD identity that can hold federated credentials and expose a
`clientId`. The CI workflow (`azure/login`) only consumes that `clientId` — it does
not care which kind it is.

We use a **user-assigned managed identity** (`id-eurotransit-ci`): it never has a
client secret, so there is nothing to leak or rotate. If your app-repo workflow
comment still says "app registration", update it to "managed identity" — the
`AZURE_CLIENT_ID` secret works identically either way.

## The chain

1. **Identity** — user-assigned managed identity `id-eurotransit-ci` → has a `clientId`.
2. **Federated credential** — the trust "GitHub Actions on
   `repo:cpo-g01-capstone/eurotransit-app:ref:refs/heads/main` may act as this
   identity". No secret is exchanged.
3. **RBAC** — that identity gets **AcrPush** scoped to `acreurotransitg01` only.
4. **AKS pull** — the AKS kubelet identity gets **AcrPull** via `--attach-acr`.
5. **Three GitHub secrets** on the app repo — `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID`. These are **IDs, not passwords** — that is the point of OIDC.

## Run it (once, as Owner)

```bash
az login                              # as the subscription Owner
cd infra/acr-oidc

./setup-acr-oidc.sh ci                # (a) app-repo push identity + federated cred + AcrPush
./setup-acr-oidc.sh aks               # (b) attach ACR to AKS (AcrPull)
./setup-acr-oidc.sh config-ci         # (c) config-repo READ-ONLY identity + federated cred + AcrPull
./setup-acr-oidc.sh secrets           # print the 3 GitHub secrets for the app repo

# or all at once:
./setup-acr-oidc.sh all
```

The script is **idempotent** — re-running skips resources that already exist. Every
value has a default from ADR 0001 and can be overridden by env var, e.g.:

```bash
GH_BRANCH=main GH_ALLOW_PR=true ./setup-acr-oidc.sh ci
```

## After running

- **App repo** (`cpo-g01-capstone/eurotransit-app`): set the 3 `AZURE_*` secrets
  (the `secrets` step prints ready-to-paste `gh secret set` commands). The CI
  workflow's `azure/login` step then authenticates via OIDC and `docker push`es to
  `acreurotransitg01.azurecr.io`.
- **This repo**: because AKS pull uses `--attach-acr` (kubelet AcrPull),
  `global.imagePullSecrets` is already `[]` in `deploy/charts/eurotransit/values.yaml` —
  nothing to change. If you instead prefer an `acr-pull-secret`, skip the `aks` step, seal
  that secret, and set `global.imagePullSecrets: [{name: acr-pull-secret}]`.
- **Config repo** (`cpo-g01-capstone/eurotransit-config`), only if you ran `config-ci`:
  set the same 3 `AZURE_*` secrets here too (the `config-ci` step prints the commands).
  This is a **separate, read-only** identity (`id-eurotransit-config-ci`, AcrPull) so the
  config CI's `validate.yml` can check that referenced tags exist in ACR. Its `AZURE_CLIENT_ID`
  **differs** from the app repo's (different identity); `AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`
  are the same. Until these are set, that job soft-skips — nothing breaks.

## What it creates in Azure

| Resource | Name | Scope |
|---|---|---|
| User-assigned managed identity | `id-eurotransit-ci` | `rg-eurotransit-g01` |
| Federated credential | `gh-eurotransit-app-main` | on the identity |
| Role assignment | `AcrPush` | `acreurotransitg01` (registry only) |
| Role assignment (via `--attach-acr`) | `AcrPull` | AKS kubelet → `acreurotransitg01` |
| User-assigned managed identity (`config-ci`) | `id-eurotransit-config-ci` | `rg-eurotransit-g01` |
| Federated credentials (`config-ci`) | `gh-eurotransit-config-main`, `gh-eurotransit-config-pr` | on the config identity |
| Role assignment (`config-ci`) | `AcrPull` (read only) | `acreurotransitg01` (registry only) |

## Least-privilege notes

- `AcrPush` is scoped to the **registry**, not a resource group or subscription.
- The federated credential is scoped to **one repo + one branch** (`main`) by
  default. `GH_ALLOW_PR=true` adds a `pull_request` subject if build-on-PR is needed.
- No secret is ever stored on the identity or in GitHub — only the `clientId`,
  `tenantId`, and `subscriptionId`.
