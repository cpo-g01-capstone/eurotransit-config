# ADR 0010 — ACR access via GitHub OIDC + a user-assigned managed identity

- **Status:** Proposed
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** ci, security, azure, acr
- **Supersedes / Superseded by:** —

---

## Context

The app-repo CI must **push** images to ACR (`acreurotransitg01`), and AKS must **pull**
them. The capstone rule is that CI never holds cluster credentials and, ideally, no
long-lived registry password either. GitHub Actions → Azure supports **OIDC federation**:
the workflow presents a short-lived GitHub-signed token that an Azure AD identity trusts,
so nothing secret is stored. Two identity types can back that federation — a **user-assigned
managed identity** or an **app registration (service principal)** — and the pull side can use
either an attached kubelet identity or an image-pull secret.

## Decision

1. **Push (CI → ACR):** GitHub OIDC federation into a **user-assigned managed identity**
   (`id-eurotransit-ci`), granted **AcrPush scoped to the registry only**. A federated
   credential trusts `repo:cpo-g01-capstone/eurotransit-app:ref:refs/heads/main`. The three
   `AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID` secrets on the app repo are **IDs, not
   passwords**.
2. **Pull (AKS → ACR):** `az aks update --attach-acr` grants the **kubelet AcrPull**; the
   chart therefore sets `global.imagePullSecrets: []` in `values-azure.yaml`.
3. Provisioning is a checked-in, idempotent script — `infra/acr-oidc/` — run once by the
   subscription Owner, not wired into CI.

## Alternatives considered

- **App registration (service principal) instead of a managed identity.** Functionally
  equivalent for OIDC (CI consumes a `clientId` either way). Chosen against: a managed
  identity never has a client secret to leak or rotate, and is slightly cleaner to reason
  about. (Any stale "app registration" wording in the workflow is corrected to match.)
- **Long-lived ACR admin user / registry password as a secret.** Rejected: a stored
  credential, the exact thing OIDC removes; also broader than push-only.
- **Image-pull secret on AKS instead of `--attach-acr`.** Viable and kept as a documented
  fallback, but `--attach-acr` needs no secret in the cluster and no sealing. Chosen for
  simplicity; if attach is undesirable, seal an `acr-pull-secret` instead.

## Consequences

**Easier / better:**
- No long-lived registry credential anywhere; push auth is a per-run OIDC exchange.
- Least privilege: AcrPush scoped to one registry, federation scoped to one repo + branch.
- Reproducible via `infra/acr-oidc/` rather than undocumented portal clicks.

**Harder / risks:**
- One-time Owner-run control-plane setup (identity, federated credential, role assignment).
- `--attach-acr` couples pull auth to the kubelet identity; if the node pool identity is
  rebuilt, re-attach. The pull-secret fallback avoids that at the cost of a managed secret.
- Adding a second pushing repo/branch means adding another federated-credential subject.

## Verification & ownership (agentic-coding policy)

- [ ] Confirm the managed identity has **AcrPush on the registry only** (no broader scope).
- [ ] Confirm the federated credential subject matches the app repo + branch that pushes.
- [ ] Run app-repo CI on `main` once: image lands in ACR, AKS pulls it (no `ImagePullBackOff`).
- [ ] Confirm `global.imagePullSecrets: []` once `--attach-acr` is in place.

## References

- Setup: `infra/acr-oidc/README.md` + `infra/acr-oidc/setup-acr-oidc.sh` (EM-41).
- ADR 0007 — the sibling decision for cross-repo GitOps write-back (GitHub App).
- ADR 0001 — ACR name/registry resource-group definitions.
