#EuroTransit cluster management (AKS / GitOps)

#if you do not have just use one of the following commands to install it
#brew install just
#cargo install just


set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# ==========================================================================
# Bootstrap — AKS (the graded cloud target)
#
# Brings up the GitOps stack on the CURRENT kube-context, which MUST be the AKS
# cluster. Infra — the AKS cluster, ACR, public IP, DNS — must ALREADY exist
# (see ADR 0001); these recipes only install Argo CD and point the app-of-apps
# at a chosen branch. Argo reconciles everything else.
#
# Defaults to `main` (the source of truth). Pass a feature branch to validate
# unmerged work on the cluster before opening its PR; the normal path is main.
#   just aks-creds                 # fetch kubeconfig + switch context to AKS
#   just aks-bootstrap             # -> full stack from `main`
#   just aks-bootstrap feature/EM-xx-...   # -> test an unmerged branch
# ==========================================================================

#fetch the AKS kubeconfig (ADR 0001 resource names) and switch context to it
aks-creds RG="rg-eurotransit-g01" CLUSTER="aks-eurotransit-g01":
    az aks get-credentials --resource-group {{ RG }} --name {{ CLUSTER }} --overwrite-existing
    @echo "Kubeconfig updated. Current context:"
    kubectl config current-context

#bootstrap the GitOps stack on the CURRENT (AKS) context, app-of-apps from BRANCH.
#Installs Argo CD, then points the app-of-apps + leaf Applications at BRANCH
#(committed files untouched). Requires BRANCH to be PUSHED (Argo pulls from the
#remote). An explicit confirmation guards the paid cluster before anything runs.
#For the steady state, prefer `kubectl apply -f bootstrap/root-app.yaml` —
#root-app tracks main and manages the whole app-of-apps tree; this recipe is
#mainly for testing an unmerged branch.
#Usage: just aks-bootstrap [BRANCH]   (BRANCH defaults to main)
aks-bootstrap BRANCH="main":
    #!/usr/bin/env bash
    set -euo pipefail
    ctx=$(kubectl config current-context)
    echo "About to bootstrap the GitOps stack on a paid cluster:"
    echo "  context: $ctx"
    echo "  branch : {{ BRANCH }}  (app-of-apps + prod/kafka/data source)"
    read -r -p "Continue? [y/N] " ans
    [ "$ans" = y ] || [ "$ans" = Y ] || { echo "Aborted."; exit 1; }
    just install-argocd
    echo "Pointing Argo at branch '{{ BRANCH }}' (committed files untouched)..."
    # HEAD→BRANCH override hits the app-of-apps + prod/kafka/data leaves only.
    for f in bootstrap/apps/argocd.yaml bootstrap/apps/platform.yaml apps/eurotransit.yaml apps/kafka.yaml apps/data-infrastructure.yaml; do
      echo "  applying $f @ {{ BRANCH }}"
      sed "s|targetRevision: HEAD|targetRevision: {{ BRANCH }}|" "$f" | kubectl apply -f -
    done
    echo "Done. Watch reconciliation: just argocd-status"
    echo "NOTE: app pods ImagePullBackOff until ACR images exist (see the ACR task)."

#one-time ACR OIDC / pull provisioning (EM-41). Run once as the subscription
#Owner: creates the CI managed identity + federated credential + AcrPush, attaches
#ACR to AKS for pull, and prints the GitHub OIDC secrets. See infra/acr-oidc/README.md.
#Usage: just acr-oidc [ci|aks|secrets|all]   (defaults to all)
acr-oidc STEP="all":
    bash infra/acr-oidc/setup-acr-oidc.sh {{ STEP }}

#install Argo CD itself (pinned via bootstrap/install/kustomization.yaml)
install-argocd:
    @echo "Creating argocd namespace..."
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    @echo "Installing Argo CD (pinned release)..."
    # --server-side: the Argo CD CRDs are too large for client-side apply
    # (last-applied-configuration annotation exceeds the size limit).
    kubectl apply -k bootstrap/install --server-side
    @echo "Waiting for Argo CD CRDs and server to be ready..."
    kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
    kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
    @echo "Argo CD ready."

#apply the app-of-apps root Application; Argo CD reconciles everything else
apply-root-app:
    @echo "Applying the app-of-apps root Application..."
    kubectl apply -f bootstrap/root-app.yaml
    @echo "root-app applied. Argo CD reconciles platform (wave 0) then workloads (wave 1)."

#show the Argo CD Application sync/health status
argocd-status:
    kubectl get applications -n argocd

#open the Argo CD UI locally: prints the admin password, then port-forwards.
#Browse https://localhost:8080 (user: admin), accept the self-signed cert. Ctrl-C to stop.
argocd-ui:
    @echo "Argo CD admin password:"
    @kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
    @echo "Opening https://localhost:8080  (user: admin). Ctrl-C to stop the port-forward."
    kubectl -n argocd port-forward svc/argocd-server 8080:443

#status of nodes and main components
status:
    kubectl get nodes -o wide
    kubectl get pods -A

# --------------------------------------------------------------------------
# Helm chart verification (offline, no cluster)
# --------------------------------------------------------------------------

CHART := "deploy/charts/eurotransit"

# Render all templates and check for syntax errors
helm-template:
    @echo "Rendering Helm templates..."
    helm template eurotransit {{ CHART }} --namespace eurotransit > /dev/null
    @echo "OK: templates render without errors."

# Run helm lint against the chart
helm-lint:
    @echo "Linting Helm chart..."
    helm lint {{ CHART }} --strict
    @echo "OK: lint passed."

# Render templates with the Azure overlay applied (catches a broken values-azure.yaml)
helm-template-azure:
    @echo "Rendering Helm templates with Azure overlay..."
    helm template eurotransit {{ CHART }} --namespace eurotransit \
        -f {{ CHART }}/values.yaml -f {{ CHART }}/values-azure.yaml > /dev/null
    @echo "OK: Azure overlay renders without errors."

# Render and check that no plaintext Secret manifests were generated
helm-check-secrets:
    @echo "Checking for plaintext Secret manifests..."
    helm template eurotransit {{ CHART }} --namespace eurotransit \
        | grep -n "^kind: Secret" && echo "ERROR: plaintext Secret found — use SealedSecret" && exit 1 \
        || echo "OK: no plaintext Secrets found."

# Render and check that no application Service is publicly exposed. Only Traefik
# (a platform component, not in this chart) may be a LoadBalancer; every service
# in the app chart must be ClusterIP. Fails on any LoadBalancer/NodePort.
helm-check-services:
    @echo "Checking all app Services are ClusterIP (not public)..."
    helm template eurotransit {{ CHART }} --namespace eurotransit \
        | grep -nE "type: (LoadBalancer|NodePort)" && echo "ERROR: app Service is publicly exposed — must be ClusterIP" && exit 1 \
        || echo "OK: all app Services are ClusterIP."

# Full offline check: lint + template render + no plaintext secrets + no public services
# Run this before every commit; does not require a cluster.
helm-verify: helm-lint helm-template helm-template-azure helm-check-secrets helm-check-services
    @echo "All offline checks passed."

# Schema-validate rendered manifests with kubeconform (compensating control for the
# SkipDryRunOnMissingResource decision — ADR 0003). Requires: brew install kubeconform.
# Not part of helm-verify (extra tool + network); intended for CI.
helm-schema:
    bash scripts/helm-schema.sh {{ CHART }}

# --------------------------------------------------------------------------
# Platform verification (no cluster; needs network to pull charts)
#
# Confirms every pinned operator chart version in platform/*/*.yaml actually
# exists and renders. Catches a typo'd or yanked chart version before Argo CD
# ever tries to sync it (a bad targetRevision otherwise fails silently at sync
# time). Versions are read straight from the Application manifests, so this can
# never drift from what Argo will deploy.
# --------------------------------------------------------------------------

# Verify every pinned platform chart version exists and renders (no cluster)
platform-verify:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "Verifying pinned platform chart versions render (needs network, no cluster)..."
    fail=0
    for f in platform/*/*.yaml; do
      grep -q '^kind: Application' "$f" || continue
      chart=$(awk -F'chart:' '/^[[:space:]]+chart:[[:space:]]/{print $2; exit}' "$f" | tr -d " \"'\r")
      [ -n "$chart" ] || continue   # skip git-source Applications (no chart field)
      repo=$(awk -F'repoURL:' '/repoURL:/{print $2; exit}' "$f" | tr -d " \"'\r")
      ver=$(awk -F'targetRevision:' '/targetRevision:/{print $2; exit}' "$f" | sed 's/#.*//' | tr -d " \"'\r")
      if helm template verify "$chart" --repo "$repo" --version "$ver" >/dev/null 2>&1; then
        printf '  PASS  %-24s @ %s\n' "$chart" "$ver"
      else
        printf '  FAIL  %-24s @ %s  (%s)\n' "$chart" "$ver" "$f"
        fail=1
      fi
    done
    if [ "$fail" -eq 0 ]; then
      echo "OK: all pinned platform charts resolve and render."
    else
      echo "ERROR: a pinned chart version is missing or won't render."
      exit 1
    fi
