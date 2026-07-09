# Agent: Delivery Owner — GitOps, Progressive Delivery, Kafka Wiring

## Scope

Primary ownership of:
- **Configuration repository** layout, structure, and integrity
- **Argo CD** installation, Application definition, sync/health lifecycle
- **GitOps delivery loop**: CI → config-repo commit → Argo CD reconcile → cluster
- **Progressive delivery**: canary and blue/green strategies via `TraefikService`
- **Strimzi / Kafka wiring**: operator installation, `Kafka` CR, `KafkaTopic` CRs, producer/consumer connection secrets
- **Sealed Secrets** bootstrap and the sealing workflow used by all teammates
- **Platform bootstrap manifests** (Traefik, cert-manager, Argo CD, Sealed Secrets, Strimzi, Chaos Mesh)

Cross-cutting awareness (not primary owner, but must understand end-to-end):
- Kubernetes probe semantics (how readiness gates interact with canary traffic split)
- Observability pipeline (ServiceMonitor, PrometheusRule — I review these before merge)
- Chaos experiment scheduling (I coordinate timing so experiments don't conflict with active canary rollouts)
- CloudNativePG failover behaviour (affects RTO claims in chaos experiment reports)

---

## Decisions made

### Two-repository split
**Decision:** strict separation — application repo owns source + CI; configuration repo owns desired state only.
**Rationale:** CI must never hold cluster credentials. Argo CD reads config-repo from inside the cluster. This split is the course requirement and was established in Lab03/Lab04.

### CI does not deploy directly
**Decision:** CI workflow ends by committing a tag bump to `deploy/charts/eurotransit/values.yaml` in the config-repo and pushing. Argo CD detects the diff and reconciles.
**Rationale:** Direct `kubectl apply` or `helm upgrade` from CI requires cluster credentials in GitHub Actions, which is explicitly forbidden by the capstone spec.

### Image tagging strategy
**Decision:** short Git SHA (`${GITHUB_SHA::7}`) for all images pushed to ACR.
**Rationale:** immutable, traceable, zero ambiguity. Semantic versioning is for production releases; we are in a course dev environment.

### Argo CD sync policy
**Decision:** `automated.selfHeal: true`, `automated.prune: true`.
**Rationale:** Git is the single source of truth. Any manual drift must be corrected automatically. `prune: true` ensures stale resources do not accumulate when templates are removed.

### Rollback mechanism
**Decision:** rollback = `git revert <commit>` on config-repo + push. Never `kubectl rollout undo`.
**Rationale:** With `selfHeal: true`, an out-of-band rollback is treated as drift and corrected. Git revert is the only safe rollback path.

### Progressive delivery implementation
**Decision:** canary via `TraefikService` weighted routing; blue/green via switching the Ingress backend service reference.
**Rationale:** Traefik is already the cluster ingress; no additional controller needed.

### Kafka deployment
**Decision:** Strimzi operator, single-broker for development, 3-broker for production topology. Topics created as `KafkaTopic` custom resources (not auto-created).
**Rationale:** Operator-managed topics are declarative, versionable, and survive broker restarts. Auto-creation is disabled to prevent silent topic proliferation.

### Sealed Secrets scope
**Decision:** strict scope (`--scope strict`) — each SealedSecret is bound to a specific name + namespace.
**Rationale:** prevents accidental reuse of a sealed value in a different namespace. Breaking decryption on rename is a feature, not a bug.

### Single Helm chart for all five services
**Decision:** one chart at `deploy/charts/eurotransit/` covering all five services; no per-service charts.
**Rationale:** CI stays simple — one `values.yaml`, one commit per build, one place to bump image tags. Per-service charts would give independent rollback granularity and team ownership, but at the cost of 5× boilerplate, 5 Argo CD Applications, and a more complex CI that updates each chart separately. At this team size (5 people, shared repo, tight timeline) the overhead is not justified. Single-service rollback is still possible by reverting one image tag in `values.yaml`.

---

## Constraints and invariants

**Do NOT change without discussing with me:**

1. **The CI workflow must not contain `kubectl` or `helm upgrade` commands targeting the cluster.** Any PR adding cluster credentials to GitHub Actions secrets or adding direct deploy steps will be rejected.

2. **`selfHeal` and `prune` in the Argo CD Application must stay `true`.** Disabling either turns the config-repo into a suggestion rather than a source of truth.

3. **All Kafka topics must be declared as `KafkaTopic` CRs in the config-repo**, not created programmatically in application code. Topic names are fixed:
   - `order-placed`
   - `inventory-reserved`
   - `payment-authorized`
   - `order-confirmed`
   - `notification-requested`

4. **`TraefikService` canary weights are the only mechanism for canary traffic splitting.** Do not introduce a service mesh or another ingress controller for this purpose.

5. **Image tags in `values.yaml` are updated only by the CI bot commit** (`github-actions[bot]`). Manual edits to image tags in `values.yaml` are allowed only for emergency hotfixes, documented in `docs/agent-log.md`.

6. **Sealed Secrets controller namespace is `sealed-secrets`.** The controller name is `sealed-secrets`. These values are baked into every `kubeseal` invocation in the justfile; changing them breaks all existing sealed manifests.

7. **The Argo CD Application points to `deploy/charts/eurotransit/` in the config-repo `main` branch.** Changing the path or branch requires updating the Application CR and re-syncing — coordinate with the team first.

---

## How to contribute to my area

### Touching the Helm chart (`deploy/charts/eurotransit/`)
- Run `just helm-verify` before opening a PR (lint + template render + plaintext secret check — no cluster needed)
- Run `just helm-schema` for kubeconform schema validation of the rendered manifests (no cluster needed)
- Do not hardcode image tags — use `{{ .Values.<service>.image.tag }}`
- Every new template file needs a corresponding entry in `values.yaml` with safe defaults
- If you add a new secret dependency, seal it first and commit only the `SealedSecret`

### Touching the CI workflow (`.github/workflows/ci.yml` in app-repo)
- The `update-gitops` job writes to the config repo via a **GitHub App installation token** (`actions/create-github-app-token`, secrets `CONFIG_REPO_APP_ID` / `CONFIG_REPO_APP_PRIVATE_KEY`), never `GITHUB_TOKEN`. See ADR 0007 + `infra/gitops-writeback-app/README.md`.
- Never add `az aks get-credentials`, `kubectl`, or `helm upgrade` steps targeting the real cluster
- If you change the `yq` path to `values.yaml`, verify it matches the actual YAML key path

### Opening a PR that adds a Kafka topic
1. Add the `KafkaTopic` CR in `deploy/charts/eurotransit/templates/kafka-topics/`
2. Add the topic name to the table in `docs/design/kafka-topics.md`
3. Confirm with the async/domain owner that consumer group IDs and offsets are correct

### Progressive delivery changes
- Canary PRs must include the `TraefikService` manifest AND the revised `values.yaml` weight
- Blue/green switch PRs must keep the old Deployment present (with 0 weight or unreferenced) until the PR is validated in demo
- Record the delivery strategy used in `docs/capstone-dod.md` under Pillar D

### Review checklist for PRs touching my area
- [ ] No cluster credentials in GitHub Actions
- [ ] `helm lint` passes
- [ ] All new secrets are `SealedSecret`, not `Secret`
- [ ] Kafka topics are declared as CRs, not created in code
- [ ] Image tag references use `{{ .Values... }}`, not literals
- [ ] `selfHeal` and `prune` untouched in the Argo CD Application CR

---

## Open questions

- **Kafka replication factor in dev** — single-broker means `replication.factor=1`. This is acceptable for dev but must be flagged clearly. Should we add a `min.insync.replicas=1` override or accept the Strimzi default?

- **Argo CD AppProject** — ✅ resolved (ADR 0011, EM-42): two scoped projects — `platform` (broad, cluster-scoped install rights) and `eurotransit` (locked to the `eurotransit` namespace, no cluster-scoped power). Defined in `bootstrap/apps/projects.yaml`.

- **Webhook vs polling for Argo CD sync trigger** — default polling is every 3 min + jitter. A GitHub webhook (config-repo → Argo CD `/api/webhook`) reduces lag to seconds. Worth adding before the demo.

- **Canary promotion criteria** — the capstone says "watch SLIs, promote or abort" but does not define the threshold. This must be agreed with the Observability owner before the canary demo. Proposed: error rate < 1% and p95 < 300ms over 5 minutes.

- **Strimzi version pin** — the operator version is pinned in the platform Application (`platform/strimzi/strimzi.yaml`), the single source of truth now that the manual install path is gone. Confirm `targetRevision` is a fixed version, not `HEAD`.

- **Blue/green cleanup timing** — how long do we keep the old Deployment around after switching traffic? Need to define a policy (e.g. one successful health check cycle = 5 minutes).

---

## Useful context for AI

When generating artifacts in this area, the following context is fixed and must not be changed:

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
      - name: eurotransit-orders        # stable track, starts at 100
        port: 80
        weight: 100
      - name: eurotransit-orders-canary  # canary track, starts at 0
        port: 80
        weight: 0
```
Adjust weights in `traefik-services.yaml` to shift traffic. The IngressRoute in `ingress.yaml` routes through this TraefikService during a canary rollout.

### Kafka topic CR pattern
```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: order-placed
  namespace: eurotransit
  labels:
    strimzi.io/cluster: eurotransit-kafka
spec:
  partitions: 3
  replicas: 1          # 1 for dev, 3 for production
  config:
    retention.ms: 604800000   # 7 days
    min.insync.replicas: "1"
```

### CI update-gitops job (canonical snippet)
```yaml
# Mint a short-lived, org-owned token scoped to the config repo (ADR 0007).
- name: Mint config-repo token (GitHub App)
  id: app-token
  uses: actions/create-github-app-token@v1
  with:
    app-id: ${{ secrets.CONFIG_REPO_APP_ID }}
    private-key: ${{ secrets.CONFIG_REPO_APP_PRIVATE_KEY }}
    owner: ${{ github.repository_owner }}
    repositories: eurotransit-config
- name: Checkout config repo
  uses: actions/checkout@v4
  with:
    repository: ${{ github.repository_owner }}/eurotransit-config
    token: ${{ steps.app-token.outputs.token }}
    path: config
- name: Update image tags in config-repo
  run: |
    yq e '.<service>.image.tag = "${{ needs.detect-changes.outputs.short_sha }}"' \
      -i config/deploy/charts/eurotransit/values.yaml
- name: Commit and push
  working-directory: config
  run: |
    git config user.name "${{ steps.app-token.outputs.app-slug }}[bot]"
    git config user.email "<bot-user-id>+${{ steps.app-token.outputs.app-slug }}[bot]@users.noreply.github.com"
    git add deploy/charts/eurotransit/values.yaml
    git diff --cached --quiet && exit 0
    git commit -m "ci: bump <service> image tag to ${{ needs.detect-changes.outputs.short_sha }}"
    git push
```
Cross-repo write-back uses a **GitHub App** (org-owned, Contents: write on `eurotransit-config` only, short-lived per-run token), not a personal PAT — see ADR 0007. The app repo holds `CONFIG_REPO_APP_ID` + `CONFIG_REPO_APP_PRIVATE_KEY`; setup is in `infra/gitops-writeback-app/README.md`. Never use `GITHUB_TOKEN` for cross-repo writes.

### Sealing workflow (justfile recipe used by all teammates)
```bash
# Usage: just seal <secret-name> <namespace>
# Requires: kubeseal installed, sealed-secrets controller running
seal name namespace:
  kubectl create secret generic {{name}} \
    --namespace {{namespace}} \
    --from-env-file=.env.{{name}} \
    --dry-run=client -o yaml \
  | kubeseal \
      --controller-name sealed-secrets \
      --controller-namespace sealed-secrets \
      --scope strict \
      --format yaml \
  > deploy/charts/eurotransit/templates/sealedsecret-{{name}}.yaml
```

### Namespace and release name
- Application namespace: `eurotransit`
- Helm release name: `eurotransit`
- Argo CD namespace: `argocd`
- Monitoring namespace: `monitoring`
- Sealed Secrets namespace: `sealed-secrets`
- Strimzi namespace: `strimzi-system`
- Kafka cluster name (Strimzi CR): `eurotransit-kafka`
- Kafka bootstrap (internal FQDN): `eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092`
- CloudNativePG cluster: `eurotransit-orders-db` (database: `ordersdb`, secret: `eurotransit-orders-db-app`)
- DB read-write service: `eurotransit-orders-db-rw.eurotransit.svc.cluster.local:5432`

### values.yaml image tag section (canonical shape)
The ACR registry is a global prefix, not baked into each repository field. CI only bumps `tag`.

```yaml
global:
  imageRegistry: ""           # empty for the baseline; "myacr.azurecr.io" for AKS
  imagePullSecrets: []        # [{name: acr-pull-secret}] for AKS

catalog:
  image:
    repository: eurotransit/catalog
    tag: "latest"             # CI overwrites with short SHA on every push to main
    pullPolicy: IfNotPresent
orders:
  image:
    repository: eurotransit/orders
    tag: "latest"
    pullPolicy: IfNotPresent
inventory:
  image:
    repository: eurotransit/inventory
    tag: "latest"
    pullPolicy: IfNotPresent
payments:
  image:
    repository: eurotransit/payments
    tag: "latest"
    pullPolicy: IfNotPresent
notifications:
  image:
    repository: eurotransit/notifications
    tag: "latest"
    pullPolicy: IfNotPresent
```

### Rollback procedure (for AI-generated runbooks)
```bash
# 1. Find the last known-good commit in config-repo
git log --oneline -- deploy/charts/eurotransit/values.yaml

# 2. Revert the bad commit
git revert <bad-commit-sha>
git push

# 3. Argo CD detects diff → becomes OutOfSync → reconciles to reverted state
# Watch:
kubectl get application -n argocd eurotransit -w
kubectl rollout status deployment/eurotransit-orders -n eurotransit
```

### What "Synced and Healthy" means in this project
- **Synced:** live cluster state matches the Helm-rendered manifests from `main` in config-repo
- **Healthy:** all Deployments have minimum available replicas; all Pods pass readiness; CloudNativePG cluster is `Ready`; Kafka cluster is `Ready`
- A service can be Synced but Unhealthy (e.g. bad image tag → CrashLoopBackOff) — treat this as a deployment failure requiring rollback
