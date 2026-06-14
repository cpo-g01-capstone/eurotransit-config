# CLAUDE.md — EuroTransit Capstone Project Reference

This file is the authoritative reference for Claude Code (or any agentic coding assistant)
working in this repository. Read it before generating any artifact, manifest, or code.

---

## Project overview

**Course:** Cloud Programming and Operations 2025-26
**Project:** EuroTransit Marketplace — a multi-service train-ticket marketplace
**Goal:** Build, deliver, observe, and harden a resilient cloud-native system

The point is **not feature richness**. The point is **operational behaviour**: how the system
holds together under partial failure, Pod death, database failover, network partition, and
zero-downtime deployment.

---

## The five services

| Service       | Responsibility                          | Interaction style                                   |
|---------------|-----------------------------------------|-----------------------------------------------------|
| Catalog       | Lists products/offers; mostly reads     | Synchronous API; tolerant of staleness              |
| Orders        | Orchestrates the purchase workflow      | Synchronous entry + asynchronous pipeline           |
| Inventory     | Tracks finite seats; contended resource | Synchronous reservation + async events              |
| Payments      | Authorizes payment; must not double-charge | Synchronous call with strict idempotency         |
| Notifications | Sends confirmations                     | Fully asynchronous; failure must degrade gracefully |

**Critical path ("money path"):** client → gateway → Orders → Inventory/Payments → Kafka stages → Notifications

---

## Architecture constraints (non-negotiable)

- **API gateway:** Traefik (from Lab03) — the single north-south entrypoint
- **Async pipeline:** Kafka via the Strimzi operator
- **Database:** PostgreSQL for Orders, managed by the CloudNativePG operator
- **Events:** `order-placed`, `inventory-reserved`, `payment-authorized`, `order-confirmed`, `notification-requested`
- **Notifications** must be able to fail entirely without failing checkout (graceful degradation)
- Internal services are **ClusterIP**; only Traefik gets a public LoadBalancer
- Secrets in Git only as **SealedSecrets** (never plaintext)
- CI must **never** hold cluster credentials; it updates Git and Argo CD reconciles

---

## Repository model (two repos)

```
application-repo/          ← source code, tests, CI workflows, justfile
  backend/<service>/
  frontend/
  .github/workflows/
  tests/k6/
  justfile

configuration-repo/        ← Helm charts, manifests, platform bootstrap, docs
  deploy/charts/eurotransit/
    Chart.yaml
    values.yaml
    templates/
  platform/
    traefik-values.yaml
    argocd/
    sealed-secrets/
    observability/
    chaos-mesh/
  docs/
    capstone-dod.md
    design/
    chaos-experiments/
    agent-log.md          ← REQUIRED: tracks agent mistakes
    postmortem.md
```

CI produces immutable images → updates `values.yaml` in configuration-repo → Argo CD reconciles.

---

## Technology stack

### Language & framework
- **Kotlin** + **Spring Boot** + **Gradle** (Kotlin DSL)
- Async pipeline: **Kotlin coroutines / Flows** with structured concurrency
- Tests: **JUnit 5** in Kotlin

### Kubernetes platform components (installed once per cluster)
| Component | Purpose | Namespace |
|---|---|---|
| Traefik | Ingress controller / north-south entrypoint | `traefik` |
| cert-manager | Automatic TLS certificates via Let's Encrypt | `cert-manager` |
| CloudNativePG | PostgreSQL operator | `cnpg-system` |
| Strimzi | Kafka operator | `strimzi-system` |
| Sealed Secrets | Encrypted secrets safe for Git | `sealed-secrets` |
| Argo CD | GitOps continuous delivery | `argocd` |
| kube-prometheus-stack | Prometheus + Grafana + Alertmanager | `monitoring` |
| Chaos Mesh | Controlled chaos experiments | `chaos-testing` |

### CI/CD
- **GitHub Actions** — builds, tests, pushes images, updates config-repo
- **Azure Container Registry (ACR)** — image registry
- **Argo CD** — pull-based GitOps reconciliation
- Image tag strategy: short Git SHA for dev; semantic versioning for staging/production

### Observability
- **Spring Boot Actuator** + **Micrometer** — application metrics
- **Prometheus** — metrics collection (scrapes via `ServiceMonitor`)
- **Grafana** — dashboards (RED + USE + Four Golden Signals)
- **Alertmanager** — alert routing
- **PrometheusRule** — alerting rules declared as Kubernetes resources
- **k6** — controlled load and fault injection
- **Distributed tracing** across the money path (Tempo or compatible)

### Progressive delivery
- **Canary** — via `TraefikService`, route fraction of traffic to new version, watch SLIs, promote or abort
- **Blue/Green** — stand up new version, switch traffic, keep fast rollback

### Resilience patterns (mandatory)
- Circuit breakers on synchronous cross-service calls (Orders → Payments)
- Bulkheads — isolated resource pools
- Bounded retries with backoff + jitter on every remote call
- Backpressure / load shedding (HTTP 429 under overload)
- Graceful degradation (Notifications down → checkout still succeeds)
- PodDisruptionBudgets
- Meaningful startup / readiness / liveness probes (liveness must NOT check downstream)

### Chaos engineering
- **Chaos Mesh** — controlled failure injection
- Experiments: latency injection, Pod kill, node/AZ disruption, Kafka partition, CloudNativePG failover

---

## Four pillars and what Claude can help generate

### Pillar A — Distributed design and async execution
Claude **may generate:**
- Kotlin coroutine / Flow scaffolding for the order pipeline
- `CoroutineScope` lifecycle wiring with SIGTERM / shutdown hooks
- Readiness probe logic that refuses traffic while in-flight work drains

Claude **must not decide:**
- Service decomposition boundaries
- Where async reduces cost vs. where it would not help (CPU-bound work)
- The written analysis of blocking-vs-suspending tradeoffs

### Pillar B — Consistency under contention (Inventory)
Claude **may generate:**
- PostgreSQL conditional/atomic reservation SQL
- Idempotency key / deduplication handler skeletons
- Reservation state machine scaffolding

Claude **must not decide:**
- The CAP/PACELC consistency model choice and its justification
- What is sacrificed in a partition
- The idempotency scheme design

### Pillar C — Resilience engineering
Claude **may generate:**
- Circuit breaker configuration (Resilience4j or equivalent)
- Retry + backoff + jitter configuration
- Probe definitions in Helm templates
- PodDisruptionBudget manifests
- HPA manifests

Claude **must not decide:**
- Open/half-open policy thresholds
- Fallback strategy (cached / degraded / queued / explicit error)
- Which flows share resource pools and which are isolated

### Pillar D — Delivery, observability, proof
Claude **may generate:**
- Helm chart templates (Deployment, Service, Ingress, ServiceMonitor, PrometheusRule)
- Argo CD Application manifests
- GitHub Actions workflow snippets
- SealedSecret manifests (from plaintext provided by the team)
- Grafana dashboard JSON
- PrometheusRule YAML
- k6 test scripts
- `TraefikService` canary / blue-green manifests

Claude **must not decide:**
- SLO definitions or error-budget statements
- Which SLIs to measure
- Which alerts should page vs. which are informational
- Chaos experiment hypotheses and conclusions

---

## Async lifecycle requirements (Pillar A specifics)

Every service with a Kafka consumer or coroutine scope **must** implement:

```kotlin
// Structured concurrency — one CoroutineScope per failure domain
val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

// Cooperative cancellation on SIGTERM
Runtime.getRuntime().addShutdownHook(Thread {
    serviceScope.cancel()
    // drain in-flight work, then proceed
})

// Readiness flips REFUSING while draining
// Spring Actuator: ReadinessStateHealthIndicator
```

The team must **demonstrate** (not claim):
- In-flight work finishes or is cleanly cancelled on shutdown
- No orphaned tasks
- No double-processing
- Readiness refuses traffic during drain

---

## Idempotency rules (Pillar B)

Every handler on the money path must be idempotent:
- Use idempotency keys (order ID + event type as composite key)
- Deduplicate at the Kafka consumer level **and** at the database level
- A duplicated `order-placed` event must NOT double-reserve inventory
- A retried payment authorization must NOT double-charge
- Document the deduplication scheme in `docs/design/idempotency.md`

---

## Probe rules (Pillar C)

```yaml
# CORRECT — liveness checks only the local process
livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: http
  periodSeconds: 15
  failureThreshold: 3

# CORRECT — readiness checks local readiness (Kafka connection, DB availability)
readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: http
  periodSeconds: 5
  failureThreshold: 3

# WRONG — liveness must NOT check downstream dependencies
# livenessProbe checking /actuator/health (which includes DB check) = AGENT MISTAKE
```

**Liveness must never fail on transient downstream issues.**
If an agent generates a liveness probe that checks a downstream dependency, reject and correct it.

---

## Secrets policy

1. **Never commit plaintext Secret manifests** to any repository
2. Create the plaintext Secret locally, seal it with `kubeseal`, commit only the `SealedSecret`
3. The Argo CD repository credential (read access) and the CI credential (write access) are **different credentials** with different scopes
4. Database credentials come from the CloudNativePG-generated secret (`<release>-cluster-app`)
5. Kafka credentials similarly come from Strimzi-generated secrets

```bash
# Sealing workflow
kubectl create secret generic my-secret \
  --namespace eurotransit \
  --from-literal=KEY=value \
  --dry-run=client -o yaml \
  | kubeseal --controller-name sealed-secrets \
             --controller-namespace sealed-secrets \
             --format yaml \
  > deploy/charts/eurotransit/templates/sealedsecret-my-secret.yaml
```

---

## GitOps delivery rules

- CI updates `deploy/charts/eurotransit/values.yaml` with new image tags
- CI commits with conventional commit message: `ci: bump image tags to <sha>`
- Argo CD detects the change and reconciles
- **Rollback = revert the values.yaml commit in Git** (not `kubectl rollout undo`)
- `selfHeal: true` + `prune: true` in Argo CD Application — Git is the source of truth
- Platform components (Traefik, cert-manager, etc.) are not managed by the application Argo CD Application

---

## Progressive delivery patterns

### Canary (TraefikService)
```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata:
  name: eurotransit-canary
spec:
  weighted:
    services:
      - name: eurotransit-backend-stable
        weight: 90
      - name: eurotransit-backend-canary
        weight: 10
```
Watch SLIs → if error rate or p95 latency exceeds threshold → abort (set canary weight to 0) → promote (set stable to new version, remove canary).

### Blue/Green
Stand up the new Deployment alongside the old one → switch the Ingress / TraefikService → keep old Deployment for fast rollback → delete old Deployment after validation.

---

## Observability requirements

### ServiceMonitor (required in each service chart)
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: <service>-backend
  labels:
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
      - eurotransit
  selector:
    matchLabels:
      app.kubernetes.io/name: <service>-backend
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
```

### Required Prometheus metrics
- `http_server_requests_seconds_*` (from Micrometer)
- `demo_observed_requests_total` (or domain equivalent)
- Kafka consumer lag metrics (from Strimzi JMX exporter or equivalent)
- CloudNativePG metrics

### Required PromQL patterns
```promql
# Request rate
sum(rate(http_server_requests_seconds_count{namespace="eurotransit", uri!~"/actuator.*"}[2m]))

# Error percentage
100 * sum(rate(http_server_requests_seconds_count{namespace="eurotransit", status=~"5..", uri!~"/actuator.*"}[2m]))
    / sum(rate(http_server_requests_seconds_count{namespace="eurotransit", uri!~"/actuator.*"}[2m]))

# p95 latency
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="eurotransit", uri!~"/actuator.*"}[5m])))

# Pod restarts
sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="eurotransit"}[10m]))
```

### Alerting rules (symptom-based)
Alert on user-visible symptoms, **not** raw infrastructure values:
- `CheckoutHighErrorRate` — >5% 5xx on the money path for 2 minutes
- `CheckoutHighP95Latency` — p95 > 500ms on the money path for 3 minutes
- `InventoryServiceDown` — scrape target down for 1 minute
- `KafkaConsumerLagHigh` — consumer lag above threshold for 5 minutes

---

## Chaos experiments (required)

Each experiment follows the scientific method:
1. Define steady state (from SLIs/dashboards)
2. State a hypothesis
3. Inject one failure using Chaos Mesh
4. Observe in dashboards
5. Conclude — record in `docs/chaos-experiments/<experiment-name>.md`

### Required experiments
1. **Latency injection → Payments** — does the Orders circuit breaker open and fallback engage while Catalog browsing stays healthy?
2. **Pod kill → Inventory mid-reservation** — does idempotency + reservation model prevent oversell or double-charge?
3. **Node/AZ disruption** — do PDBs and topology spread keep the critical path available?
4. **Kafka partition** — does the async pipeline recover and converge? Is anything lost or duplicated?
5. **CloudNativePG primary failover** — what is the observed impact on checkout? Does the system recover within the stated RTO?

---

## Agentic coding policy (what the team agreed to)

This is the project's formal agentic coding policy, as required by the capstone spec.

**Permitted:** Agents may produce service scaffolding, Helm templates, dashboards, manifests, test harnesses, k6 scripts.

**Not permitted:** Agents may not decide service decomposition, consistency models, SLO definitions, failure-mode mapping, chaos hypotheses, or postmortem content. These are authored and owned by the team.

### Blast radius of this agent

This agent (Claude) can:
- Open pull requests against the **configuration repository** if given a `CONFIG_REPO_PAT`
- Generate manifests that Argo CD will reconcile into the cluster

Threat model (required by capstone spec, section "Agentic coding policy"):
- **Credentials held:** `CONFIG_REPO_PAT` with write access to configuration-repo; no direct cluster credentials
- **Review gate:** All agent-generated PRs require at least one human approval before merge
- **Policy-as-code:** `helm lint` and `helm template | kubeval` run in CI on every configuration-repo PR
- **Worst case:** Agent proposes a bad manifest → Argo CD applies it → service degrades → team reverts the config-repo commit → Argo CD self-heals → documented in `agent-log.md`

### agent-log.md (required deliverable)

The file `docs/agent-log.md` must record **at least three** concrete cases where an agent-produced artifact was incorrect, unsafe, or subtly wrong. Examples of things to watch for:

| Pattern | Why it is wrong |
|---|---|
| Liveness probe checking a downstream dependency | Causes cascading restarts when downstream is slow |
| Alert rule based on CPU percentage threshold | Cause-based, not symptom-based; creates noise |
| Over-permissive `ServiceAccount` with cluster-admin | Violates least-privilege |
| Non-idempotent Kafka consumer handler | Can double-process on retry |
| `imagePullPolicy: Always` without pinned digest | Non-deterministic; can pull different code |
| `resources:` section omitted | Prevents scheduler from making good decisions |
| Secrets in `env:` as plain `value:` instead of `secretKeyRef:` | Leaks secrets in pod spec |
| `prune: false` in Argo CD Application | Stale resources accumulate |

---

## Justfile conventions

The application repository must expose these `just` recipes:

```justfile
# Build all services
build:
  ./gradlew build

# Run all tests
test:
  ./gradlew test

# Build a specific service image
image-build service:
  docker build -t {{service}}:local ./{{service}}

# Run local verification (build → test → image → health check)
verify:
  just build && just test && just image-build orders && ...

# Generate a SealedSecret (requires kubeseal and cluster access)
seal name namespace:
  kubectl create secret generic {{name}} --namespace {{namespace}} \
    --from-env-file=.env.{{name}} --dry-run=client -o yaml \
    | kubeseal --controller-name sealed-secrets \
               --controller-namespace sealed-secrets \
               --format yaml \
    > deploy/charts/eurotransit/templates/sealedsecret-{{name}}.yaml

# Run chaos experiment
chaos experiment:
  kubectl apply -f docs/chaos-experiments/{{experiment}}.yaml

# Local k6 traffic (baseline)
load-baseline:
  BASE_URL=https://gXX.cpo2026.it VUS=3 DURATION=3m k6 run tests/k6/baseline.js
```

---

## Naming conventions

| Resource | Pattern |
|---|---|
| Namespace | `eurotransit` |
| Release name | `eurotransit` |
| Deployment | `eurotransit-<service>` |
| Service | `eurotransit-<service>` |
| ServiceMonitor | `eurotransit-<service>` |
| PrometheusRule | `eurotransit-<service>` |
| SealedSecret | `eurotransit-<name>` |
| Argo CD Application | `eurotransit` |
| Kafka topics | `order-placed`, `inventory-reserved`, `payment-authorized`, `order-confirmed`, `notification-requested` |
| CloudNativePG cluster | `eurotransit-orders-db` |
| PostgreSQL services | `eurotransit-orders-db-rw` (primary), `eurotransit-orders-db-ro` (read-only) |

---

## Common mistakes to reject

The following patterns are known agent failure modes. If Claude generates any of these, the team must reject and correct them, and record the case in `agent-log.md`.

1. **Liveness probe checking DB or Kafka** — liveness must only check the local process health
2. **`imagePullPolicy: Always` without a digest pin** — use `IfNotPresent` with immutable image tags
3. **Missing `resources:` on any container** — always set requests and limits
4. **Hardcoded image tags in Deployment YAML** — tags must come from `values.yaml`
5. **`ClusterRoleBinding` where a `RoleBinding` would suffice** — minimize cluster-wide permissions
6. **Alert firing on CPU > X%** — alerts must be symptom-based (error rate, latency, availability)
7. **`selfHeal: false` in the Argo CD Application** — must be `true` for GitOps to enforce state
8. **Uncommitted plaintext secrets** — any `kind: Secret` with base64 data must be replaced by a `SealedSecret`
9. **CI workflow with `kubectl apply` and cluster credentials** — CI must only update Git; Argo CD deploys
10. **Non-idempotent Kafka handlers** — every consumer must handle redelivery safely
11. **Missing `PodDisruptionBudget`** for any service on the critical path
12. **`Notification` service failure propagated to checkout** — Notifications must degrade gracefully

---

## Kubernetes object quick reference

```bash
# Argo CD
kubectl get applications -n argocd
kubectl describe application eurotransit -n argocd

# Sealed Secrets
kubectl get sealedsecrets -n eurotransit
kubectl get secret -n eurotransit

# CloudNativePG
kubectl get cluster -n eurotransit
kubectl get pods,pvc,svc -n eurotransit | grep orders-db

# Strimzi / Kafka
kubectl get kafka -n eurotransit
kubectl get kafkatopic -n eurotransit

# Chaos Mesh
kubectl get chaos -n eurotransit

# Observability
kubectl get servicemonitor -n eurotransit
kubectl get prometheusrule -n eurotransit
kubectl get pods -n monitoring

# Port-forwarding for observability UIs
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```

---

## Helm chart structure

```
deploy/charts/eurotransit/
  Chart.yaml              ← declares dependencies (Strimzi, CloudNativePG cluster chart)
  values.yaml             ← image tags (updated by CI), replica counts, resource limits
  templates/
    catalog/
      deployment.yaml
      service.yaml
      servicemonitor.yaml
      hpa.yaml
    orders/
      deployment.yaml
      service.yaml
      servicemonitor.yaml
      prometheusrule.yaml
    inventory/
      deployment.yaml
      service.yaml
    payments/
      deployment.yaml
      service.yaml
    notifications/
      deployment.yaml
      service.yaml
    shared/
      pdb-orders.yaml
      pdb-payments.yaml
      pdb-inventory.yaml
    ingress.yaml
    traefik-services.yaml   ← canary / blue-green TraefikService resources
    sealedsecrets/
      sealedsecret-*.yaml
```

---

## SLO definitions (team to complete)

The team must define at minimum:
- **Latency SLO:** p95 checkout latency < ___ ms over ___ minutes
- **Success-rate SLO:** ≥ ___% of checkout requests succeed over ___ minutes
- **Error budget statement:** how much error budget is consumed per experiment

These numbers are decisions the team must own. Claude should not invent them.

---

## Definition of Done checklist (abbreviated)

The full DoD lives in `docs/capstone-dod.md`. At minimum it must cover:

- [ ] Pillar A: Service decomposition documented with sync/async boundaries justified
- [ ] Pillar A: Order pipeline async with correct coroutine lifecycle (cancellation, drain)
- [ ] Pillar B: Consistency model chosen, justified (CAP/PACELC), implemented
- [ ] Pillar B: Idempotency on the full money path, documented and tested under chaos
- [ ] Pillar C: Circuit breakers, bulkheads, timeouts, retries, backpressure, graceful degradation
- [ ] Pillar C: PDBs, probes, HPA configured deliberately
- [ ] Pillar D: GitOps delivery via Argo CD; CI never holds cluster creds
- [ ] Pillar D: Canary and blue-green both demonstrated
- [ ] Pillar D: Per-service RED dashboards; USE/infrastructure dashboards
- [ ] Pillar D: Symptom-based SLO alerts; distributed tracing across money path
- [ ] Chaos: All five experiments run, documented (hypothesis → observation → conclusion)
- [ ] Agentic coding: `docs/agent-log.md` with ≥3 agent mistakes caught and corrected
- [ ] Deliverables: Two repos with history; docs/; 5-min recorded demo; live presentation scheduled

---

*This file was generated from the capstone project specification and the Lab01–Lab05 materials. Update it as the team makes design decisions that narrow constraints further.*
