# Agent: Vojtech — Delivery & Platform

## Scope

I am responsible for the **Delivery & Platform** area of EuroTransit. My scope includes:

- The Helm chart at `deploy/charts/eurotransit/` — the single source of truth for all Kubernetes manifests
- Argo CD installation and the App-of-Apps bootstrap under `bootstrap/`
- GitOps delivery loop: CI commits a tag bump → Argo CD reconciles → cluster converges
- Progressive delivery: canary via `TraefikService` weighted routing; blue/green via Ingress switch
- Platform operators declared in `platform/` (Traefik, cert-manager, CloudNativePG, Strimzi, kube-prometheus-stack, Sealed Secrets)
- Kafka infrastructure: Strimzi operator, `Kafka` CR, `KafkaTopic` CRs in `kafka/`
- Sealed Secrets workflow — sealing, scoping, and the `just seal` recipe
- Local development cluster: `k3d-config.yaml`, `Justfile`, bootstrap scripts

## Decisions made

- **Single Helm chart** for all five services (`deploy/charts/eurotransit/`). One `values.yaml` updated by CI; no per-service charts.
- **Global image registry** via `global.imageRegistry` in `values.yaml`. Local k3d leaves it empty; AKS sets it to the ACR hostname. CI bumps only the `tag` field — never the registry prefix.
- **`imagePullPolicy: IfNotPresent`** everywhere. Tags are immutable SHAs; pulling on every restart would be wasteful and non-deterministic.
- **All services ClusterIP** — only Traefik gets a public endpoint. Internal routing stays inside the cluster.
- **Liveness probes check `/actuator/health/liveness` only.** Never downstream. Readiness checks `/actuator/health/readiness`, which includes Kafka + DB availability.
- **`terminationGracePeriodSeconds: 60`** with a 5s `preStop` sleep on all pods. Gives coroutines time to drain without dropping in-flight requests.
- **Kafka wiring via Argo CD Application** (`apps/kafka.yaml`) — no more manual `kubectl apply -f kafka/`.
- **Single Helm chart for all five services** (`deploy/charts/eurotransit/`). Per-service charts were considered and rejected — they give independent rollback and team ownership but add 5× boilerplate, 5 Argo CD Applications, and a more complex CI. At this team size the overhead isn't justified; single-service rollback still works by reverting one image tag in `values.yaml`.
- **Symptom-based PrometheusRules only** — `CheckoutHighErrorRate`, `CheckoutHighP95Latency`, `InventoryServiceDown`, `KafkaConsumerLagHigh`. No CPU/memory alerts.
- **`selfHeal: true` + `prune: true`** on all Argo CD Applications. Git is the only source of truth; drift is corrected automatically.
- **Rollback = `git revert` on config-repo.** Never `kubectl rollout undo` — selfHeal would immediately re-apply the unwanted state.

## Constraints and invariants

Do NOT change without discussing with me:

1. **`selfHeal` and `prune` must stay `true`** in every Argo CD Application.
2. **Image tags in `values.yaml` are updated only by the CI bot.** Manual edits are emergency-only and must be documented in `docs/agent-log.md`.
3. **No `kubectl`/`helm upgrade` in CI workflows.** CI writes to Git; Argo CD deploys.
4. **All secrets must be `SealedSecret`.** No `kind: Secret` in the chart. The `just helm-check-secrets` recipe enforces this.
5. **Liveness probes must not check downstream dependencies.** This is a hard rule — liveness checking Kafka or DB causes cascading restarts.
6. **`resources:` must be set on every container.** Missing resources prevent the scheduler from making good decisions and are caught by `helm lint --strict`.
7. **Kafka topics are declared as `KafkaTopic` CRs in `kafka/`.** Never auto-created in application code.
8. **The Argo CD Application points at `deploy/charts/eurotransit/` in `main`.** Changing path or branch requires coordinating with the team and re-syncing.

## How to contribute to my area

### Before opening any PR touching the Helm chart

Run the offline gate — no cluster needed:
```bash
just helm-verify    # lint + template render + no plaintext secrets
```

If you have a cluster available, also run:
```bash
just helm-dry-run   # server-side dry-run catches unknown CRDs and invalid values
```

### Adding a new Kubernetes resource

1. Add the template under `deploy/charts/eurotransit/templates/<service>/`
2. Add any new value it depends on to `values.yaml` with a safe default
3. Run `just helm-verify` — must pass before the PR is opened
4. If the resource references a secret, seal it first with `just seal <name> eurotransit`

### Touching the platform (`platform/`)

- Each file is an Argo CD `Application` manifest — changes are applied by committing and pushing to `main`
- Pin chart versions explicitly; avoid `targetRevision: HEAD` for production operators
- Namespace changes require updating `bootstrap/apps/platform.yaml` if the path or destination changes

### Review checklist for PRs touching my area

- [ ] `just helm-verify` passes (lint + template + no plaintext secrets)
- [ ] No cluster credentials added anywhere
- [ ] New secrets are `SealedSecret`, not `Secret`
- [ ] Image tag references use `{{ .Values.<service>.image.tag }}`, not literals
- [ ] `resources:` set on every new container
- [ ] Liveness probe does NOT check DB or Kafka
- [ ] `selfHeal` and `prune` untouched in Argo CD Applications

## Open questions

- **Argo CD AppProject** — should we scope the Application to a named `AppProject` to restrict blast radius? Low effort, good practice before the demo.
- **Argo CD webhook** — default polling is every 3 min. A GitHub webhook reduces sync lag to seconds. Worth adding before the live demo.
- **Canary promotion thresholds** — need to be agreed with the Observability owner. Proposed: error rate < 1% and p95 < 300ms sustained over 5 minutes before promoting.
- **Blue/green cleanup policy** — how long to keep the old Deployment after switching traffic? Proposed: delete after one full health-check cycle (≈5 min) with no errors.
- **Grafana admin secret** — `kube-prometheus-stack.yaml` uses the default `prom-operator` password for local dev. Must be replaced with a `SealedSecret` before the AKS deployment.
- **Prometheus storage** — currently `emptyDir` (ephemeral). Need a PVC with the AKS `managed-csi` storage class before the demo cluster is stood up.

## Useful context for AI

When generating artifacts in this area, the following is fixed:

### Helm chart structure
```
deploy/charts/eurotransit/
  Chart.yaml
  values.yaml              ← CI updates <service>.image.tag here
  templates/
    <service>/deployment.yaml, service.yaml, servicemonitor.yaml
    catalog/hpa.yaml
    orders/prometheusrule.yaml
    shared/pdb-orders.yaml, pdb-inventory.yaml, pdb-payments.yaml
    ingress.yaml            ← Traefik IngressRoute
    traefik-services.yaml   ← TraefikService for canary/blue-green
```

### Image reference pattern (global registry prefix)
```yaml
# values.yaml
global:
  imageRegistry: ""           # empty = local; set to "myacr.azurecr.io" for AKS
  imagePullSecrets: []        # set to [{name: acr-pull-secret}] for AKS

catalog:
  image:
    repository: eurotransit/catalog
    tag: "latest"             # CI overwrites this
    pullPolicy: IfNotPresent
```
```yaml
# In deployment template
image: {{ include "eurotransit.imageRef" (list .Values.global.imageRegistry .Values.catalog.image) }}
```

### Argo CD Application (canonical form)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: eurotransit
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/cpo-g01-capstone/eurotransit-config.git'
    targetRevision: HEAD
    path: deploy/charts/eurotransit
    helm:
      releaseName: eurotransit
      valueFiles:
        - values.yaml
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: eurotransit
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Canary TraefikService pattern
```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: eurotransit-orders-weighted
  namespace: eurotransit
spec:
  weighted:
    services:
      - name: eurotransit-orders        # stable track
        port: 80
        weight: 100
      - name: eurotransit-orders-canary  # canary track, starts at 0
        port: 80
        weight: 0
```

### Probe rules (non-negotiable)
```yaml
# CORRECT
livenessProbe:
  httpGet:
    path: /actuator/health/liveness   # local process only
    port: http
  periodSeconds: 15
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /actuator/health/readiness  # checks Kafka + DB connection
    port: http
  periodSeconds: 5
  failureThreshold: 3

# WRONG — liveness must never check a downstream dependency
# livenessProbe checking /actuator/health (full health including DB) = agent mistake
```

### Rollback procedure
```bash
git log --oneline -- deploy/charts/eurotransit/values.yaml
git revert <bad-commit-sha>
git push
# Argo CD detects diff → OutOfSync → reconciles to reverted state
kubectl get application -n argocd eurotransit -w
```

### Namespace and naming reference
| Resource | Value |
|---|---|
| Application namespace | `eurotransit` |
| Helm release name | `eurotransit` |
| Argo CD namespace | `argocd` |
| Monitoring namespace | `monitoring` |
| Sealed Secrets namespace | `sealed-secrets` (controller name: `sealed-secrets`) |
| Strimzi namespace | `strimzi-system` |
| Kafka cluster CR name | `eurotransit-kafka` |
| Kafka bootstrap (internal) | `eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092` |
| CloudNativePG cluster | `eurotransit-orders-db` |
| DB read-write service | `eurotransit-orders-db-rw.eurotransit.svc.cluster.local:5432` |
| DB app secret | `eurotransit-orders-db-app` (keys: `username`, `password`) |
