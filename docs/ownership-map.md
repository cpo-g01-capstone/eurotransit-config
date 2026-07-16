# Ownership map — who owns which code, per domain

Per-owner index of the source code, manifests, and docs each role is responsible for,
across **both repos**: **config** = `eurotransit-config` (this repo) · **app** =
`eurotransit-app`. Assignments come from the team's CODEOWNERS path blocks (both repos),
the stated doc owners, and the role table in the README — nothing here is newly decided.

**This map is orientation, not a review gate.** Review policy stays *single approval from
any team member* (ADR 0019); the path-specific CODEOWNERS blocks are commented out and
this map mirrors them. Ownership means: you keep the area coherent, you're the first
reviewer to ask for, and roles are for coordination — everyone must still understand the
full money path end to end (*(app)* `docs/roles.md`).

| GitHub | Role |
|--------|------|
| [@vojtech-n](#vojtech-n--delivery-owner) | Delivery — GitOps, Argo CD, Kafka wiring, progressive delivery |
| [@giova95](#giova95--resilience-owner) | Resilience — circuit breakers, chaos experiments, probes, PDBs |
| [@Lollegro](#lollegro--domain--async-owner) | Domain & async — service decomposition, coroutines, Kafka pipeline |
| [@marcodonatucci](#marcodonatucci--observability--verification--pm) | Observability & verification + PM |
| [@MauroC0l](#mauroc0l--data--consistency-owner) | Data & consistency — CloudNativePG, inventory model, idempotency |

---

## @vojtech-n — Delivery owner

*The path from a merged commit to a converged cluster, and the platform it runs on.*
Detailed scope + invariants: [`agents/vojtech.md`](agents/vojtech.md), `.agent/agents/delivery-owner.md`.

**config**

| Path | What it is |
|---|---|
| `deploy/charts/eurotransit/` | The single Helm chart — `Chart.yaml`, `values.yaml`, `templates/_helpers.tpl`, chart-wide structure (per-service template *content* is co-owned with the service's domain owner, below) |
| `bootstrap/` | Argo CD install (Kustomize seed, ADR 0028), root app, AppProjects (ADR 0011) |
| `apps/` | Argo CD Applications: `eurotransit`, `kafka`, `data-infrastructure` |
| `platform/argocd/`, `platform/traefik/`, `platform/cert-manager/`, `platform/sealed-secrets/`, `platform/strimzi/` | Platform operators + Argo CD/TLS exposure |
| `kafka/` | Strimzi wiring: `kafka-broker.yaml`, `kafka-topics.yaml`, `kafka-users.yaml` (topic *semantics* — who produces/consumes — sit with @Lollegro) |
| `infra/` | ACR OIDC setup, GitOps write-back GitHub App (ADR 0007/0010) |
| `Justfile`, `scripts/` | helm-verify/schema gates, sealing recipe, seed script |
| `.claude/`, `.agent/` | Agent permission rules and role context |
| `DELIVERY.md`, `docs/delivery/` (all runbooks), `docs/design/data-flow.md` | Delivery decision index, operational runbooks, verified money-path topology |

**app**

| Path | What it is |
|---|---|
| `.github/workflows/ci.yml` | The whole pipeline, esp. the `update-gitops` job — the GitOps boundary (no cluster creds, ever) |
| `justfile` | Build/test/verify recipes |
| `backend/*/Dockerfile`, `frontend/Dockerfile` | Image build contract with CI/ACR |

---

## @giova95 — Resilience owner

*How the system behaves when parts of it fail — and the experiments proving it.*

**config**

| Path | What it is |
|---|---|
| `platform/chaos-mesh/` | Chaos Mesh operator install (ADR 0017) |
| `docs/chaos-experiments/` | CE-1…CE-6: hypotheses, manifests, run reports (conclusions team-ratified) |
| `deploy/charts/eurotransit/templates/shared/` | The six PDBs + default-deny NetworkPolicy |
| `values.yaml` `probes:`/`lifecycle:` blocks | Probe timings, drain budget, `preStop` — with @vojtech-n (chart structure) per ADR 0002/0027 |

**app**

| Path | What it is |
|---|---|
| `backend/orders-service/.../client/PaymentsClient.kt` | Circuit breaker + retry + timeout decoration and the queued-retry fallback (ADR 0018) |
| `backend/orders-service/.../config/PaymentsWebClientConfig.kt` | The `payments-bulkhead` dedicated connection pool |
| `backend/{orders,inventory}-service/.../config/KafkaErrorHandlingConfig.kt` | Kafka redelivery backoff / error handlers |
| `backend/orders-service/src/main/resources/application.yml` — `resilience4j.*` | Breaker / retry / ratelimiter (429 shedding) instances |
| `tests/k6/ce2-contention.js` | Contention driver for CE-2 (k6 home base is @marcodonatucci's) |

---

## @Lollegro — Domain & async owner

*Service decomposition and the coroutine/Kafka pipeline that moves an order through it.*

**config**

| Path | What it is |
|---|---|
| `deploy/charts/eurotransit/templates/orders/`, `templates/notifications/` | Deployments/Services for his two services (canary track machinery itself: @vojtech-n) |
| `docs/design/service-boundaries.md` | The decomposition + sync/async rule + async cost analysis |
| `.agent/context/kafka-topics.md` | Producer/consumer table — must move in the same PR as `docs/design/data-flow.md` (app ADR-001) |

**app**

| Path | What it is |
|---|---|
| `backend/orders-service/` | Sync entry (`controller/`), orchestration (`service/`), producers/consumers (`kafka/`), events, model |
| `backend/notifications-service/` | Terminal consumer, DLT handling, graceful-degradation contract |
| `backend/*/.../lifecycle/` (`GracefulShutdownManager` pattern) | Structured concurrency, SIGTERM drain, readiness flip — the Pillar A lifecycle |
| *(app)* ADRs on pipeline semantics (canonical orders impl, notifications 0001–0004) | |

---

## @marcodonatucci — Observability & verification + PM

*Whether we can see it, whether the numbers are ratified, and whether the project converges.*

**config**

| Path | What it is |
|---|---|
| `platform/monitoring/` | kube-prometheus-stack, Tempo, Grafana exposure |
| `deploy/charts/eurotransit/dashboards/` + `templates/observability/` | RED + USE dashboards (GitOps-delivered), capacity rules |
| `deploy/charts/eurotransit/templates/*/prometheusrule.yaml`, `*/servicemonitor.yaml` | SLI recording rules, burn-rate alerts, scrape config |
| `deploy/charts/eurotransit/templates/catalog/` | Catalog manifests (incl. blue/green track — mechanism: @vojtech-n) |
| `deploy/charts/eurotransit/templates/frontend/`, `templates/shared/pdb-frontend.yaml` | Frontend manifests |
| `docs/design/slo-definitions.md` | Ratified SLOs / error budget — single source of truth for thresholds |
| `docs/agent-log.md` (custodian), `docs/postmortem.md` | Graded verification deliverables (entries come from everyone) |

**app**

| Path | What it is |
|---|---|
| `backend/catalog-service/` | The stateless, event-fed AP cache service |
| `frontend/` | The web frontend (Vite/TS) — build, deploy config, docs |
| `tests/k6/` | `baseline.js`, `checkout-e2e.js` — load + SLI drivers |
| Micrometer/tracing wiring — `application.yml` OTLP exporters, tracing deps in `build.gradle.kts` | Metrics + trace instrumentation across services (ADR 0022) |

---

## @MauroC0l — Data & consistency owner

*State: PostgreSQL clusters, the contended inventory model, and idempotency everywhere.*
Detailed scope: [`agents/mauro.md`](agents/mauro.md).

**config**

| Path | What it is |
|---|---|
| `postgres/` | All four CloudNativePG `Cluster` CRs (orders, inventory, payments, notifications — ADR 0020/0024) |
| `platform/cloudnative-pg/` | The CNPG operator install |
| `deploy/charts/eurotransit/templates/inventory/`, `templates/payments/` | Deployments/Services/HPA for his two services |
| `docs/design/consistency.md`, `docs/design/idempotency.md` | CAP/PACELC choice; the dedup scheme (required deliverable) |

**app**

| Path | What it is |
|---|---|
| `backend/inventory-service/` | Atomic reservation SQL (`repository/RouteRepository.kt`), reservation flow, seat-release compensation |
| `backend/payments-service/` | No-double-charge (`PaymentService`, `PaymentIntentRepository`) |
| `backend/*/src/main/resources/db/migration/` | Flyway schemas: constraints, `processed_events`, `idempotency_records`, `sent_notifications` |
| `backend/*/.../repository/ProcessedEventRepository.kt` pattern | In-transaction consumer dedup across services |

---

## Shared — no single owner

| Path | Note |
|---|---|
| `docs/capstone-dod.md`, `docs/agent-log.md`, `docs/postmortem.md` | Graded collective deliverables — whole team (agent-log custodian: @marcodonatucci) |
| `deploy/charts/eurotransit/values.yaml` — `<service>.image.tag` | Owned by **the CI bot**, not a person; manual edits are emergency-only + agent-log entry |
| `UBIQUITOUS_LANGUAGE.md`, `README.md`, `CLAUDE.md`/`AGENTS.md` | Team-wide reference |

---

## Keeping this map honest

- New directory / service / doc → add it to the right owner's table **in the same PR**.
- If ownership changes, update this map **and** the commented CODEOWNERS blocks in both
  repos together — they must mirror each other so re-enabling enforcement is one uncomment.
- Cross-boundary rows (probe values, canary machinery, kafka topics) name **both** parties
  deliberately: the first name keeps it coherent, the second reviews changes to it.
