#!/usr/bin/env bash
# =============================================================================
# EuroTransit — ACR OIDC / pull provisioning (EM-41, IaC)
#
# One-time Azure control-plane provisioning that lets:
#   (a) GitHub Actions in the APP repo push images to ACR via OIDC — NO secret,
#   (b) the AKS cluster pull those images.
#
# This is CONTROL-PLANE setup, run once by the subscription Owner (the credit
# holder). It is intentionally NOT wired into any CI workflow: the capstone rule
# is that CI never holds Azure/cluster credentials (see CLAUDE.md, delivery-owner).
# Checking this script in makes the identity reproducible and reviewable instead
# of living as undocumented tribal knowledge (ADR 0006 posture: Azure-only, IaC).
#
# Idempotent: safe to re-run. Each step checks for existing resources.
#
# Prereqs:
#   - az CLI logged in as an Owner of the subscription  (az login)
#   - the ACR + AKS already exist (ADR 0001)
#   - gh CLI logged in, if you use the `secrets` step to set repo secrets
#
# Usage:
#   ./setup-acr-oidc.sh ci        # (a) managed identity + federated cred + AcrPush
#   ./setup-acr-oidc.sh aks       # (b) attach ACR to AKS kubelet (AcrPull)
#   ./setup-acr-oidc.sh secrets   # print / set the 3 GitHub OIDC secrets
#   ./setup-acr-oidc.sh all       # ci + aks + print secrets
#
# Override any value via env, e.g.  GH_BRANCH=main ACR_NAME=... ./setup-acr-oidc.sh ci
# =============================================================================
set -euo pipefail

# --- Configuration (defaults from ADR 0001) ----------------------------------
LOCATION="${LOCATION:-polandcentral}"

ACR_NAME="${ACR_NAME:-acreurotransitg01}"
ACR_RG="${ACR_RG:-rg-acreurotransitg01}"

AKS_NAME="${AKS_NAME:-aks-eurotransit-g01}"
AKS_RG="${AKS_RG:-rg-eurotransit-g01}"

# User-assigned managed identity that GitHub Actions federates into.
IDENTITY_NAME="${IDENTITY_NAME:-id-eurotransit-ci}"
IDENTITY_RG="${IDENTITY_RG:-rg-eurotransit-g01}"

# GitHub repo that BUILDS and PUSHES images (the app repo, not this config repo).
GH_ORG="${GH_ORG:-cpo-g01-capstone}"
GH_APP_REPO="${GH_APP_REPO:-eurotransit-app}"
GH_BRANCH="${GH_BRANCH:-main}"      # CI pushes images on push to main
# Also allow pull_request runs to authenticate (e.g. build-only smoke). Set to
# "false" to keep least-privilege to the main branch only.
GH_ALLOW_PR="${GH_ALLOW_PR:-false}"

# -----------------------------------------------------------------------------
log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required but not installed." >&2; exit 1; }
}

resolve_account() {
  SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
  TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"
  log "Subscription: ${SUBSCRIPTION_ID}"
  log "Tenant:       ${TENANT_ID}"
}

# --- (a) CI push identity: managed identity + federated cred + AcrPush --------
setup_ci() {
  require az
  resolve_account

  log "Ensuring user-assigned managed identity '${IDENTITY_NAME}' in '${IDENTITY_RG}'"
  az identity create \
    --name "${IDENTITY_NAME}" \
    --resource-group "${IDENTITY_RG}" \
    --location "${LOCATION}" \
    --only-show-errors >/dev/null

  local client_id principal_id
  client_id=$(az identity show -n "${IDENTITY_NAME}" -g "${IDENTITY_RG}" --query clientId -o tsv)
  principal_id=$(az identity show -n "${IDENTITY_NAME}" -g "${IDENTITY_RG}" --query principalId -o tsv)
  log "Identity clientId=${client_id}"

  # Federated credential(s): the trust that "GitHub Actions on <subject> may act
  # as this identity". Subject must match the token GitHub mints for the run.
  add_federated_cred() {
    local name="$1" subject="$2"
    if az identity federated-credential show \
         --name "${name}" --identity-name "${IDENTITY_NAME}" -g "${IDENTITY_RG}" \
         --only-show-errors >/dev/null 2>&1; then
      echo "  federated-credential '${name}' already exists — skipping"
    else
      echo "  creating federated-credential '${name}'  subject=${subject}"
      az identity federated-credential create \
        --name "${name}" \
        --identity-name "${IDENTITY_NAME}" \
        --resource-group "${IDENTITY_RG}" \
        --issuer "https://token.actions.githubusercontent.com" \
        --subject "${subject}" \
        --audiences "api://AzureADTokenExchange" \
        --only-show-errors >/dev/null
    fi
  }

  log "Ensuring federated credentials for ${GH_ORG}/${GH_APP_REPO}"
  add_federated_cred "gh-${GH_APP_REPO}-${GH_BRANCH}" \
    "repo:${GH_ORG}/${GH_APP_REPO}:ref:refs/heads/${GH_BRANCH}"
  if [ "${GH_ALLOW_PR}" = "true" ]; then
    add_federated_cred "gh-${GH_APP_REPO}-pr" \
      "repo:${GH_ORG}/${GH_APP_REPO}:pull_request"
  fi

  # AcrPush on the ACR scope only (least privilege — cannot touch anything else).
  local acr_id
  acr_id=$(az acr show -n "${ACR_NAME}" -g "${ACR_RG}" --query id -o tsv)
  log "Assigning AcrPush to the identity on ${ACR_NAME}"
  # --assignee-object-id + principal type avoids a Graph lookup that can race
  # right after the identity is created.
  az role assignment create \
    --assignee-object-id "${principal_id}" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPush \
    --scope "${acr_id}" \
    --only-show-errors >/dev/null 2>&1 \
    && echo "  AcrPush assigned" \
    || echo "  AcrPush already present (or propagating) — skipping"

  CI_CLIENT_ID="${client_id}"   # exported for the secrets step
}

# --- (b) AKS pull: attach ACR to the kubelet identity (AcrPull) ---------------
setup_aks() {
  require az
  log "Attaching ACR '${ACR_NAME}' to AKS '${AKS_NAME}' (grants kubelet AcrPull)"
  az aks update \
    --name "${AKS_NAME}" \
    --resource-group "${AKS_RG}" \
    --attach-acr "${ACR_NAME}" \
    --only-show-errors >/dev/null
  echo "  Done. With attach-acr, imagePullSecrets are NOT needed —"
  echo "  global.imagePullSecrets is already [] in deploy/charts/eurotransit/values.yaml."
}

# --- (c) GitHub secrets the app-repo workflow expects -------------------------
print_secrets() {
  resolve_account
  local client_id="${CI_CLIENT_ID:-}"
  if [ -z "${client_id}" ]; then
    client_id=$(az identity show -n "${IDENTITY_NAME}" -g "${IDENTITY_RG}" --query clientId -o tsv 2>/dev/null || true)
  fi

  log "GitHub Actions secrets for ${GH_ORG}/${GH_APP_REPO} (OIDC — these are IDs, not passwords):"
  cat <<EOF
  AZURE_CLIENT_ID        ${client_id:-<run the 'ci' step first>}
  AZURE_TENANT_ID        ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID  ${SUBSCRIPTION_ID}

  Set them with the gh CLI (run against the APP repo):
    gh secret set AZURE_CLIENT_ID       -R ${GH_ORG}/${GH_APP_REPO} -b "${client_id:-<client-id>}"
    gh secret set AZURE_TENANT_ID       -R ${GH_ORG}/${GH_APP_REPO} -b "${TENANT_ID}"
    gh secret set AZURE_SUBSCRIPTION_ID -R ${GH_ORG}/${GH_APP_REPO} -b "${SUBSCRIPTION_ID}"
EOF
}

# --- dispatch ----------------------------------------------------------------
case "${1:-all}" in
  ci)      setup_ci ;;
  aks)     setup_aks ;;
  secrets) print_secrets ;;
  all)     setup_ci; setup_aks; print_secrets ;;
  *)       echo "Usage: $0 {ci|aks|secrets|all}" >&2; exit 2 ;;
esac

log "Done."
