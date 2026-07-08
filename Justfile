#EuroTransit cluster management

#if you do not have just use one of the following commands to install it
#brew install just
#cargo install just


set windows-shell := ["powershell.exe", "-NoLogo", "-Command"]

# Operator versions — MUST match the pinned targetRevision in platform/*/*.yaml.
# The manual bootstrap path below installs the same versions the GitOps path
# (Argo CD) reconciles, so switching paths never creates a version mismatch.
STRIMZI_VERSION := "1.1.0"
CNPG_VERSION := "0.29.0"

# ==========================================================================
# Local cluster (k3d) — the ENVIRONMENT. Used by BOTH bootstrap paths.
# k3d is a disposable local Kubernetes for testing manifests/operators before
# they reach AKS. The cluster is multi-node (see k3d-config.yaml) so PDBs and
# topology spread (Pillar C) can actually be exercised.
# ==========================================================================

#creating the local k3d cluster using declarative configuration (idempotent:
#reuses an existing cluster so `bootstrap` / `bootstrap-manual` can be re-run)
up:
    #!/usr/bin/env bash
    set -euo pipefail
    if k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx eurotransit-cluster; then
      echo "Cluster 'eurotransit-cluster' already exists — reusing it."
      k3d kubeconfig merge eurotransit-cluster --kubeconfig-merge-default >/dev/null
    else
      echo "Creating the local k3d cluster..."
      k3d cluster create --config k3d-config.yaml
    fi
    echo "Cluster ready! Context: k3d-eurotransit-cluster"

#delete
down:
    @echo "Deleting the local k3d cluster..."
    k3d cluster delete eurotransit-cluster

#status of nodes and main components
status:
    kubectl get nodes -o wide
    kubectl get pods -A

# ==========================================================================
# Bootstrap — GitOps path (RECOMMENDED, matches the capstone requirement)
#
# The only imperative step is installing Argo CD itself (it cannot bootstrap
# from nothing). After that, Argo CD is the single source of truth: it installs
# the platform operators (wave 0) then the workloads (wave 1) from git.
#
# NOTE: Argo CD syncs the REMOTE `main` branch. Local, unpushed changes are NOT
# reconciled — push the branch (or point the Application at it) to test them
# end-to-end. To test uncommitted changes without Argo, use `bootstrap-manual`.
# ==========================================================================

#one-shot GitOps bootstrap: cluster + Argo CD + app-of-apps (Argo does the rest)
bootstrap: up install-argocd apply-root-app
    @echo "GitOps bootstrap complete. Watch reconciliation with: just argocd-status"

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

#LOCAL TEST: bootstrap Argo pointing at a feature BRANCH instead of main, WITHOUT
#editing or committing any manifest. Overrides targetRevision at apply-time and
#applies the platform app-of-apps + workload leaf Applications directly (skipping
#root-app/workloads so they don't re-pull the HEAD copies and undo the override).
#Requires the branch to be PUSHED first (Argo pulls from the remote, not local).
#Use this to validate an unmerged branch on k3d; the real bootstrap uses main.
#Usage: just bootstrap-branch feature/EM-31-Platform-bootstrap-sync-order-and-version-pinning
bootstrap-branch BRANCH: up install-argocd
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Pointing Argo at branch '{{ BRANCH }}' (committed files untouched)..."
    for f in bootstrap/apps/platform.yaml apps/eurotransit.yaml apps/kafka.yaml apps/data-infrastructure.yaml; do
      echo "  applying $f @ {{ BRANCH }}"
      sed "s|targetRevision: HEAD|targetRevision: {{ BRANCH }}|" "$f" | kubectl apply -f -
    done
    echo "Done. Watch reconciliation: just argocd-status"
    echo "NOTE: app pods will ImagePullBackOff until images exist in the registry."

# ==========================================================================
# Bootstrap — AKS (the graded cloud target)
#
# Brings up the GitOps stack on the CURRENT kube-context, which MUST be the AKS
# cluster. Infra — the AKS cluster, ACR, public IP, DNS — must ALREADY exist
# (see ADR 0001); these recipes only install Argo CD and point the app-of-apps
# at a chosen branch. Argo reconciles everything else.
#
# Defaults to `staging`: `main` is currently behind (it lacks the chart/platform/
# ADR stack), so bootstrapping against `main` would deploy almost nothing. Point
# at an explicit branch to override; use `main` once it has caught up.
#   just aks-creds                 # fetch kubeconfig + switch context to AKS
#   just aks-bootstrap             # -> full stack from `staging`
#   just aks-bootstrap main        # -> once main is the source of truth
# ==========================================================================

#fetch the AKS kubeconfig (ADR 0001 resource names) and switch context to it
aks-creds RG="rg-eurotransit-g01" CLUSTER="aks-eurotransit-g01":
    az aks get-credentials --resource-group {{ RG }} --name {{ CLUSTER }} --overwrite-existing
    @echo "Kubeconfig updated. Current context:"
    kubectl config current-context

#bootstrap the GitOps stack on the CURRENT (AKS) context, app-of-apps from BRANCH.
#Mirrors bootstrap-branch but: no `up` (AKS already exists), a k3d context guard,
#and an explicit confirmation before it touches a paid cluster. Requires BRANCH to
#be PUSHED (Argo pulls from the remote). Excludes apps/eurotransit-staging.yaml —
#that App self-targets `staging` and is only wanted once a real prod (main) runs
#alongside it; bootstrapping the prod leaves FROM `staging` already deploys the
#staging code into the eurotransit namespace for testing.
#Usage: just aks-bootstrap [BRANCH]   (BRANCH defaults to staging)
aks-bootstrap BRANCH="staging":
    #!/usr/bin/env bash
    set -euo pipefail
    ctx=$(kubectl config current-context)
    case "$ctx" in
      k3d-*)
        echo "Refusing: current context '$ctx' is a k3d cluster, not AKS."
        echo "Run 'just aks-creds' (or 'az aks get-credentials ...') first."
        exit 1 ;;
    esac
    echo "About to bootstrap the GitOps stack on a NON-k3d context:"
    echo "  context: $ctx"
    echo "  branch : {{ BRANCH }}  (app-of-apps + prod/kafka/data source)"
    read -r -p "Continue? [y/N] " ans
    [ "$ans" = y ] || [ "$ans" = Y ] || { echo "Aborted."; exit 1; }
    just install-argocd
    echo "Pointing Argo at branch '{{ BRANCH }}' (committed files untouched)..."
    # HEAD→BRANCH override hits the app-of-apps + prod/kafka/data leaves only.
    # (apps/eurotransit-staging.yaml is intentionally NOT applied here — see above.)
    for f in bootstrap/apps/platform.yaml apps/eurotransit.yaml apps/kafka.yaml apps/data-infrastructure.yaml; do
      echo "  applying $f @ {{ BRANCH }}"
      sed "s|targetRevision: HEAD|targetRevision: {{ BRANCH }}|" "$f" | kubectl apply -f -
    done
    echo "Done. Watch reconciliation: just argocd-status"
    echo "NOTE: app pods ImagePullBackOff until ACR images exist (see the ACR task)."

# ==========================================================================
# Bootstrap — MANUAL path (escape hatch: offline / uncommitted iteration)
#
# Installs the operators and CRs directly with helm/kubectl — NO Argo CD.
# Useful for fast local iteration on manifests you have NOT pushed yet.
#
# Namespaces and versions are ALIGNED with the GitOps path (Strimzi ->
# strimzi-system watching eurotransit; CloudNativePG -> cnpg-system) so a stray
# double-run or a later switch to GitOps never produces two operators.
#
# WARNING: never run this against a cluster already managed by Argo CD.
# selfHeal:true will treat these manual resources as drift and fight them, and
# prune:true will delete anything Argo does not know about. One path per cluster.
# ==========================================================================

#full manual (non-GitOps) bootstrap: cluster + operators + topics + postgres
bootstrap-manual: up install-operator install-cnpg deploy-topics deploy-postgres
    @echo "Manual bootstrap complete. NOTE: Argo CD is NOT installed on this cluster."

#install the Strimzi operator (aligned with platform/strimzi/strimzi.yaml)
install-operator:
    @echo "Ensuring eurotransit namespace exists..."
    kubectl create namespace eurotransit --dry-run=client -o yaml | kubectl apply -f -
    @echo "Adding Strimzi Helm repository..."
    helm repo add strimzi https://strimzi.io/charts/
    helm repo update
    @echo "Installing Strimzi operator {{ STRIMZI_VERSION }} into strimzi-system (watching eurotransit)..."
    helm upgrade --install strimzi-cluster-operator strimzi/strimzi-kafka-operator \
        --namespace strimzi-system --create-namespace --version {{ STRIMZI_VERSION }} \
        --set 'watchNamespaces={eurotransit}' --set watchAnyNamespace=false
    @echo "Waiting for Strimzi cluster operator deployment to become available..."
    kubectl rollout status deployment/strimzi-cluster-operator -n strimzi-system --timeout=120s
    @echo "Strimzi operator ready in strimzi-system."

#install the CloudNativePG operator (aligned with platform/cloudnative-pg/cloudnative-pg.yaml)
install-cnpg:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Adding CloudNativePG Helm repository..."
    helm repo add cnpg https://cloudnative-pg.github.io/charts
    helm repo update
    echo "Installing CloudNativePG operator {{ CNPG_VERSION }} into cnpg-system..."
    helm upgrade --install cloudnative-pg cnpg/cloudnative-pg \
        --namespace cnpg-system --create-namespace --version {{ CNPG_VERSION }}
    echo "Waiting for CloudNativePG CRD to be established..."
    kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=120s
    # The CRD existing is NOT enough: the Cluster admission webhook needs the
    # controller pod running, or `kubectl apply -f postgres/` fails with
    # "no endpoints available for service cnpg-webhook-service". Wait for the
    # webhook service to actually have endpoints before returning.
    echo "Waiting for the CloudNativePG controller webhook endpoints..."
    for i in $(seq 1 60); do
      if kubectl -n cnpg-system get endpoints cnpg-webhook-service \
           -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; then
        echo "CloudNativePG operator ready."
        exit 0
      fi
      sleep 3
    done
    echo "ERROR: timed out waiting for cnpg-webhook-service endpoints"
    exit 1

deploy-topics:
    @echo "Waiting for Strimzi CRDs to be established..."
    kubectl wait --for=condition=Established crd/kafkas.kafka.strimzi.io crd/kafkatopics.kafka.strimzi.io --timeout=60s
    kubectl apply -f kafka/

deploy-postgres:
    @echo "Waiting for CloudNativePG CRD..."
    kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=120s
    kubectl apply -f postgres/
    @echo "Waiting for Orders DB cluster to become Ready..."
    kubectl wait --for=condition=Ready cluster/eurotransit-orders-db -n eurotransit --timeout=300s
    @echo "Orders PostgreSQL cluster is ready. Secret: eurotransit-orders-db-app"

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

# Render templates with the staging overlay (values.yaml + values-azure.yaml +
# values-staging.yaml, in the order the eurotransit-staging Argo App applies them).
# Catches a broken values-staging.yaml before Argo tries to sync it.
helm-template-staging:
    @echo "Rendering Helm templates with staging overlay..."
    helm template eurotransit {{ CHART }} --namespace eurotransit-staging \
        -f {{ CHART }}/values.yaml -f {{ CHART }}/values-azure.yaml -f {{ CHART }}/values-staging.yaml > /dev/null
    @echo "OK: staging overlay renders without errors."

# Render templates and run a client-side dry-run against the local k3d cluster.
# Requires: just up AND a cluster that has every CRD the chart references —
# Traefik (IngressRoute/TraefikService) and the Prometheus operator
# (ServiceMonitor/PrometheusRule). `bootstrap-manual` installs only Strimzi +
# CNPG, so those kinds will error with "no matches for kind ...". Run this only
# against a FULL platform (the GitOps path installs Traefik + monitoring), or
# install just those CRDs first. For a CRD-free gate use `just helm-verify`.
helm-dry-run:
    @echo "Checking k3d cluster is reachable..."
    kubectl --context k3d-eurotransit-cluster cluster-info > /dev/null
    @echo "Running client-side dry-run against k3d..."
    helm template eurotransit {{ CHART }} --namespace eurotransit \
        | kubectl --context k3d-eurotransit-cluster apply --dry-run=client -f -
    @echo "OK: dry-run passed."

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
helm-verify: helm-lint helm-template helm-template-azure helm-template-staging helm-check-secrets helm-check-services
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
