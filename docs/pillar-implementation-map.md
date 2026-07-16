# Pillar implementation map — where each requirement lives

A point-by-point index of the four capstone pillars: how EuroTransit handles each
requirement and where to find the code/docs. Paths are prefixed with the repo:

- **config** = `eurotransit-config` (this repo — Helm chart, platform, docs)
- **app** = `eurotransit-app` (Kotlin services, CI, k6)

Companion documents: [`capstone-dod.md`](capstone-dod.md) (checklist with evidence links),
[`design/data-flow.md`](design/data-flow.md) (end-to-end money-path diagram).

---

## Pillar A — Distributed design and asynchronous execution

### Service decomposition with sync/async boundaries + justification
Documented per service (Catalog, Orders, Inventory, Payments, Notifications) with the
guiding rule *"synchronous only when a decision is needed now"*. The one contested
boundary — payment authorization — was resolved by team vote as a **synchronous HTTP
call Orders → Payments** (ADR 0018); everything else on the pipeline is Kafka-driven.

- **config** `docs/design/service-boundaries.md` — the decomposition table and rule
- **config** `docs/adr/0018-sync-payment-authorization-circuit-breaker.md` — the sync boundary decision
- **config** `docs/design/data-flow.md` — producers/consumers per topic, verified against code

### Async order pipeline (Kotlin coroutines / Flows, Kafka stages)
`POST /orders` returns quickly with the order in `DRAFT`; reservation, payment
authorization and confirmation proceed through Kafka stages
(`order-placed` → `inventory-reserved` → `payment-authorized` → `order-confirmed`,
with `order-failed` as the compensation path). All handlers are `suspend` functions.

- **app** `backend/orders-service/.../controller/OrderController.kt` — sync entry point
- **app** `backend/orders-service/.../service/OrderService.kt` + `kafka/` (producer, `InventoryReservedConsumer`, `OrderKafkaConsumer`, `OrderFailedConsumer`) — the orchestration
- **app** `backend/inventory-service/.../kafka/InventoryKafkaConsumer.kt`, `backend/payments-service/`, `backend/notifications-service/.../listener/OrderConfirmedListener.kt` — the downstream stages
- **config** `kafka/kafka-topics.yaml` — all topics as `KafkaTopic` CRs (Strimzi)
- **app** `docs/adr/0005-orders-canonical-implementation-and-graceful-shutdown.md`

### Structured concurrency, SIGTERM cancellation, readiness drain
Each service has a `GracefulShutdownManager` (Spring `SmartLifecycle`, phase
`Int.MAX_VALUE` so it stops first): on SIGTERM it (1) publishes
`ReadinessState.REFUSING_TRAFFIC` → the readiness probe returns 503 and K8s removes
the pod from endpoints, (2) drains tracked in-flight operations (~45 s budget), while
consumers guard on `isAcceptingTraffic()` and skip-without-ack so unacked messages are
redelivered after rebalance (no orphaned tasks, no double-processing — dedup covers
the redelivery). Demonstrated by unit test and re-demonstrated live in CE-2/CE-3.

- **app** `backend/orders-service/.../lifecycle/GracefulShutdownManager.kt` (same pattern in `inventory-service`, `payments-service`; `notifications-service/.../lifecycle/NotificationsLifecycle.kt`)
- **app** `backend/orders-service/src/test/kotlin/.../lifecycle/GracefulShutdownManagerTest.kt`
- **config** `docs/adr/0002-graceful-shutdown-and-probes.md` — drain-chain invariant (`terminationGracePeriodSeconds: 60` > drain budget); values in `deploy/charts/eurotransit/values.yaml` (`lifecycle:` block), `preStop` sleep via `templates/_helpers.tpl`

### Written async cost analysis (blocking vs suspending)
Short analysis: pipeline stages are I/O-bound, so suspending frees threads → fewer
replicas → lower cost; CPU-bound work (serialization/crypto) would not benefit —
scale with replicas instead. References the blocking-vs-suspending lecture model.

- **config** `docs/design/service-boundaries.md` §"Async cost analysis (blocking vs suspending)"

---

## Pillar B — Consistency under contention (Inventory)

### Consistency model choice (CAP / PACELC)
Inventory is **CP / PC-EC**: under partition it rejects reservations (503 / Kafka
NACK) rather than risk overselling; without a partition it accepts optimistic-lock
retry latency (~1–5 ms/retry) over weaker consistency. Contrast: Catalog is
deliberately **AP / EL** (event-fed stale-tolerant cache, app ADR 0006).

- **config** `docs/design/consistency.md` — the full CAP/PACELC analysis and sacrifices
- **config** `docs/adr/0020-inventory-dedicated-database.md` — dedicated `inventorydb`
- **app** `docs/adr/0006-catalog-event-fed-ap-cache.md` — the AP counterpart

### Implementation (atomic reservation)
Conditional atomic `UPDATE routes SET available_seats = available_seats - :seats …
WHERE available_seats >= :seats` (row-level lock — exactly one racer wins the last
seat), plus an optimistic `version` column with bounded retry, a
`UNIQUE(order_id, route_id)` reservation constraint, and guarded seat-release
compensation (`available_seats + :seats <= total_seats` protects the invariant) on
`order-failed`.

- **app** `backend/inventory-service/.../repository/RouteRepository.kt` — the atomic SQL
- **app** `backend/inventory-service/.../service/InventoryService.kt` — reservation flow
- **app** `backend/inventory-service/.../kafka/OrderFailedConsumer.kt` — compensation (seat release)
- **app** `backend/inventory-service/src/main/resources/db/migration/` — schema/constraints

### Idempotency across the money path
Composite key `{orderId}:{eventType}`. Every Kafka consumer inserts into a
`processed_events` table **in the same DB transaction** as the business logic (pod
death rolls both back → retry reprocesses correctly). `POST /orders` accepts an
`Idempotency-Key` header; duplicates return the cached response from
`idempotency_records`. Notifications additionally keeps a durable dedup store
(`sent_notifications`, app ADR-002) so redelivered `order-confirmed` events don't
re-send email.

- **config** `docs/design/idempotency.md` — the documented scheme (required deliverable)
- **app** `backend/*/.../repository/ProcessedEventRepository.kt` + `model/ProcessedEvent.kt` (orders, inventory, payments)
- **app** `backend/orders-service/.../repository/IdempotencyRecordRepository.kt` — HTTP dedup
- **app** `backend/payments-service/.../service/PaymentService.kt` + `PaymentIntentRepository.kt` — no-double-charge
- **app** `backend/notifications-service/.../persistence/SentNotificationRepository.kt`

### Chaos proof: "never oversell" under duplicates / Pod death
CE-2 kills the Inventory pod mid-reservation under k6 contention load and verifies
the invariants directly in the database (I1: `available_seats + reserved = total`,
I2: no duplicate reservations). Executed — see run docs.

- **config** `docs/chaos-experiments/ce-2/` — hypothesis, manifest, pre-test, run 3 results
- **app** `tests/k6/ce2-contention.js` — the contention driver

---

## Pillar C — Resilience engineering

### Circuit breaker (Orders → Payments) with defined policy + fallback
Resilience4j breaker on the sync authorize call: COUNT_BASED window 20, opens at 50%
failures **or** 50% slow calls (>2 s — catches "slow death"), 30 s open,
auto-transition to half-open with 5 probe calls. Decorator order:
`Retry(CircuitBreaker(2s-timeout WebClient call))`. Fallback = **queued retry**: the
Kafka error handler redelivers, the order stays `RESERVED` — never an unbounded hang,
never a double-charge (Payments is idempotent).

- **config** `docs/adr/0018-sync-payment-authorization-circuit-breaker.md` — the policy decision
- **app** `backend/orders-service/.../client/PaymentsClient.kt` — decorated call + fallback
- **app** `backend/orders-service/src/main/resources/application.yml` — `resilience4j.circuitbreaker.instances.payments`
- **app** `backend/orders-service/src/test/kotlin/.../client/PaymentsClientResilienceTest.kt`

### Bulkheads
The Payments call runs on a **dedicated bounded Reactor Netty connection pool**
(`payments-bulkhead`), isolated from the shared WebClient resources — a slow Payments
cannot exhaust connections used by other flows.

- **app** `backend/orders-service/.../config/PaymentsWebClientConfig.kt`

### Timeouts + bounded retries with backoff and jitter
2 s timeout on the Payments call; Resilience4j retry `maxAttempts: 3`, exponential
backoff ×2 with `randomizedWaitFactor: 0.5` (jitter, anti-thundering-herd), and
`CallNotPermittedException` excluded so an OPEN breaker is never hammered. Kafka
redelivery uses `ExponentialBackOff` in the error handlers.

- **app** `backend/orders-service/src/main/resources/application.yml` — `resilience4j.retry.instances.payments`
- **app** `backend/orders-service/.../config/KafkaErrorHandlingConfig.kt` (same in `inventory-service`)

### Backpressure / load shedding (HTTP 429)
Resilience4j `RateLimiter` on `POST /orders` (50 req/s, `timeoutDuration: 0` = refuse
immediately, don't queue) → HTTP 429. Ratified judgment: 429 is controlled
degradation, **excluded from the SLO error budget**.

- **app** `backend/orders-service/src/main/resources/application.yml` — `resilience4j.ratelimiter.instances.checkout`
- **app** `backend/orders-service/.../controller/OrderController.kt` — the guarded endpoint
- **config** `docs/design/slo-definitions.md` — the 429-not-an-error decision

### Graceful degradation (Notifications down ≠ checkout failure)
Notifications is a terminal, Kafka-only consumer of `order-confirmed` — nothing on
the money path waits for it. Poison messages go to `order-confirmed.DLT`; a durable
dedup store makes recovery safe. The order is CONFIRMED regardless.

- **app** `backend/notifications-service/` (listener, `NotificationService`, DLT config in `config/KafkaConfig.kt`)
- **app** `docs/adr/0001…0004` — trigger topic, dedup store, failure handling, probes
- **config** `kafka/kafka-topics.yaml` — `order-confirmed-dlt` CR

### Probes, PDBs, topology spread (deliberate K8s resilience)
Shared probe block in `values.yaml`: liveness = `/actuator/health/liveness` (local
process only — never downstream), readiness = `/actuator/health/readiness` (internal
`ReadinessState` only — flips to `REFUSING_TRAFFIC` during drain; DB/Kafka deliberately
**not** in the readiness group, app ADR 0004), startup probe for JVM warmup. PDB per service (all five + frontend), hard
topology spread across zones, HPA on catalog/inventory/payments,
`terminationGracePeriodSeconds: 60` + `preStop` sleep.

- **config** `deploy/charts/eurotransit/values.yaml` — `probes:`/`lifecycle:` blocks
- **config** `deploy/charts/eurotransit/templates/shared/pdb-*.yaml` — six PDBs
- **config** `deploy/charts/eurotransit/templates/_helpers.tpl` — `eurotransit.topologySpread`, `eurotransit.preStop`
- **config** `docs/adr/0002` (probes/shutdown), `0021` (HA replicas, RTO/RPO), `0023` (HPA + spread + PDB), `0025` (HPA-owned replicas), `0027` (CPU rightsizing for drain headroom)

---

## Pillar D — Delivery, observability, proof under failure

### GitOps delivery (CI never holds cluster credentials)
CI builds/tests (Gradle, detekt, frontend), pushes immutable short-SHA images to ACR
via **OIDC** (no stored registry password), then a `update-gitops` job mints a
**short-lived GitHub App token** (Contents:write on the config repo only) and commits
the tag bump to `values.yaml`. Argo CD (app-of-apps from `bootstrap/root-app.yaml`,
`selfHeal: true` + `prune: true`) reconciles. Rollback = `git revert`. No
`kubectl`/`helm` against the cluster anywhere in CI.

- **app** `.github/workflows/ci.yml` — the whole pipeline incl. `update-gitops`
- **config** `apps/eurotransit.yaml` — the Argo CD Application; `bootstrap/` — root app + AppProjects (ADR 0011)
- **config** `docs/adr/0007-gitops-writeback-github-app.md`, `0010-acr-access-oidc-managed-identity.md`, `0016-config-repo-branch-protection-ci-bypass.md`
- Proof in git history: `eurotransit-gitops-writeback[bot]` commits (`ci: bump image tags to <sha>`)

### Canary (TraefikService, SLI-gated)
Orders (the money path) canaries via the weighted `TraefikService`
`eurotransit-orders-weighted` — `/api/orders` **always** routes through it, so the
wiring can't regress to dead config. The canary track (Deployment + Service +
dedicated ServiceMonitor) renders only when `orders.canary.enabled=true`; weights and
tag live in `values.yaml`, so a rollout is a sequence of Git commits. Team-ratified
promotion gate: error rate < 1% AND p95 < 300 ms for 5 min on the canary's own
metrics. Demonstrated 2026-07-11 (10.06% split, 0% 5xx, promoted).

- **config** `deploy/charts/eurotransit/templates/traefik-services.yaml`, `templates/orders/deployment-canary.yaml` + `service-canary.yaml`
- **config** `docs/adr/0026-progressive-delivery-canary-bluegreen.md`, `docs/delivery/progressive-delivery-runbook.md`
- **config** `docs/delivery/2026-07-11-progressive-delivery-demo-results.md` — the demo evidence

### Blue/green (Ingress switch, fast rollback)
Catalog (stateless) runs blue/green: green Deployment alongside blue
(`catalog.blueGreen.enabled=true`), atomic cutover at the **IngressRoute** (serves
the Service of `catalog.blueGreen.activeTrack`), old track kept for 5 clean minutes
as the instant-rollback path, then removed in one commit. Demonstrated (PRs #61–#63).

- **config** `deploy/charts/eurotransit/templates/catalog/deployment-green.yaml`, `templates/ingress.yaml`
- **config** ADR 0026 + runbook + demo-results doc (as above)

### DORA discussion (rolling / all-at-once)
Where the two remaining strategies would fit and why they're not on the critical
path: **config** `docs/adr/0026-progressive-delivery-canary-bluegreen.md` §"DORA
delivery strategies". (Rolling is still what the promoted stable track does under the
hood — deliberately, off the traffic-decision path.)

### Observability (RED, USE, symptom-based alerts)
GitOps-delivered Grafana dashboards (ConfigMaps via sidecar): a money-path RED
dashboard (incl. circuit-breaker state panel) and a USE/infrastructure dashboard.
Alerts are symptom-based only: multi-window error-budget **burn-rate** rules
(14× fast-burn pages, 6× slow-burn tickets), `CheckoutHighErrorRate`,
`CheckoutHighP95Latency`, `KafkaConsumerLagHigh`, service-down rules; CPU appears
only as a non-paging capacity ticket. Scraping via per-service `ServiceMonitor`s
(`/actuator/prometheus`, Micrometer).

- **config** `deploy/charts/eurotransit/dashboards/red-money-path.json`, `use-infrastructure.json` (+ `templates/observability/grafana-dashboards.yaml`)
- **config** `deploy/charts/eurotransit/templates/orders/prometheusrule.yaml` — SLI recording rules + burn-rate alerts; also `inventory/` and `payments/` prometheusrules, `observability/prometheusrule-capacity.yaml`
- **config** `deploy/charts/eurotransit/templates/*/servicemonitor.yaml`
- **config** `platform/monitoring/kube-prometheus-stack.yaml` — the stack itself

### SLOs + error budget
Team-ratified 2026-07-11: checkout p95 **< 500 ms**; success rate **≥ 99%** of
`POST /orders` non-5xx over 30 days → 1% error budget (≈432 min), burn-rate
alerting, deploy-freeze policy, and the 429-excluded ruling. These numbers drive the
alert thresholds, dashboard panels, and the canary gate.

- **config** `docs/design/slo-definitions.md` — single source of truth
- **config** `deploy/charts/eurotransit/templates/orders/prometheusrule.yaml` — the SLIs implemented

### Distributed tracing across the money path
OpenTelemetry via Micrometer tracing bridge, spans exported over OTLP to **Tempo**
(in `monitoring`), Grafana as the query UI. W3C trace context is propagated through
Kafka headers, so one trace answers "where did this order spend its time" across
gateway → Orders → Inventory/Payments → Kafka stages → Notifications.

- **config** `docs/adr/0022-distributed-tracing-tempo-otlp.md`; `platform/monitoring/tempo.yaml`
- **app** `backend/*/src/main/resources/application.yml` — OTLP exporter endpoint; tracing deps in `build.gradle.kts` (app PR #14 for Kafka propagation)
- **config** `deploy/charts/eurotransit/templates/shared/networkpolicy.yaml` — egress rule allowing span export

### Chaos experiments (proof under failure)
All five follow the scientific method (steady state → hypothesis → single injection →
dashboard observation → conclusion), with Chaos Mesh manifests and executed run
reports per experiment:

- **config** `docs/chaos-experiments/ce-1/` — latency → Payments (breaker opens, fallback engages)
- **config** `docs/chaos-experiments/ce-2/` — Pod kill → Inventory (never-oversell invariant)
- **config** `docs/chaos-experiments/ce-3/` — node/AZ disruption (PDBs + topology spread)
- **config** `docs/chaos-experiments/ce-4/` — Kafka partition (pipeline convergence, no loss/dup)
- **config** `docs/chaos-experiments/ce-5/` — CNPG primary failover (run 3: PASS, RTO 16.8 s, RPO 0)
- **config** `platform/chaos-mesh/chaos-mesh.yaml` — the operator install (ADR 0017)
