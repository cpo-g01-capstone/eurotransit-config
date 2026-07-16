# Agent log

Records cases where agent-produced artifacts were incorrect, unsafe, or subtly wrong.
**Minimum three entries required before the live presentation. This file is graded.**

Reviewed like any PR (single approval — ADR 0019); substantive changes should still be discussed by the whole team.

Custodian: @marcodonatucci (Observability & Verification).

Twenty-six cases were recorded during the project; by team decision (2026-07-12) this file
keeps the **thirteen with the most durable lessons**. Original case numbers are preserved —
code comments, ADRs and PRs cite them. The full record, including the retired setup-era
entries, is in Git history: `git show 53fe549:docs/agent-log.md`. (Case 24 — the CE-1
compensation guard, cited from `KafkaErrorHandlingConfig.kt` — is still awaiting its
write-up here.)

Suggested starting points: **cases 17–20** (one story: the first real order through the
gateway peeled off four invisible fault layers that had the write path dead — green CI,
passing tests and a four-auditor review had all missed them), then **15** (a rebase
conflict resolution that silently deleted a just-merged feature) and **12** (the
exception-swallowing `suspend` listener that became the team-ratified bridge pattern).

| # | Date | Area | Summary |
|---|------|------|---------|
| 12 | 2026-07-08 | Async / eurotransit-app notifications | AI-designed `suspend` @KafkaListener silently swallowed handler exceptions (no retry/DLT) |
| 13 | 2026-07-11 | Delivery / eurotransit-config | Orders chart injected `SPRING_DATASOURCE_*`, but the app reads `ORDERS_DB_*` — env ignored, app fell back to `localhost:5432` and crashlooped |
| 14 | 2026-07-11 | GitOps / eurotransit-config | chaos-mesh Application under `project: platform` sourced an external chart repo not in the AppProject's `sourceRepos` — Argo `InvalidSpecError` |
| 15 | 2026-07-08 | Async / eurotransit-app orders | Agent's rebase conflict resolution silently reverted the `order-failed` compensation publish (took `--theirs` = its own stale commit) |
| 17 | 2026-07-11 | Persistence / eurotransit-app | `repository.save()` with app-assigned @Id mapped to UPDATE — the entire write path was dead |
| 18 | 2026-07-11 | Async / eurotransit-app | Kafka JSON type headers made every cross-service event undeliverable |
| 19 | 2026-07-11 | Async / eurotransit-app | Two silent event-contract faults: frozen catalog cache and DLT'd notifications |
| 20 | 2026-07-11 | Observability / eurotransit-app | No histogram buckets behind every latency panel, alert, and canary gate — p95 was unmeasurable |
| 21 | 2026-07-12 | Chaos / eurotransit-config | CE-5 runbook injected with a graceful `kubectl delete pod` — measures CNPG smart shutdown (a switchover), not a primary crash |
| 22 | 2026-07-14 | Security / eurotransit-config | Kafka SASL helper referenced a `username` key that Strimzi KafkaUser secrets never generate |
| 23 | 2026-07-16 | Observability / eurotransit-config | USE dashboard aliased raw kube-state-metrics target fragments to one deployment name, making legend filtering contradict the graph |
| 25 | 2026-07-16 | Observability / eurotransit-app | `order.id` tag and Kafka producer spans read a ThreadLocal inside coroutines — the tag silently no-oped and every HTTP-origin `send` rooted a detached trace |
| 26 | 2026-07-16 | Notifications / eurotransit-app | AI's `SmtpEmailSender` used `setFrom(from)` inside `SimpleMailMessage().apply {}` — the receiver's own `from` bean property shadowed the constructor param, sending every email with a null sender |

---

## Case 12 — 2026-07-08 — `suspend` @KafkaListener silently swallowed exceptions (eurotransit-app)

> Caught while implementing the Notifications consumer (ADR-001..004).

**What the AI produced:**
The AI-authored design (ADR-004 / the notifications spec) and the first implementation used a
Kotlin `suspend` @KafkaListener:

```kotlin
@KafkaListener(topics = ["order-confirmed"], containerFactory = "kafkaListenerContainerFactory")
suspend fun onOrderConfirmed(event: OrderConfirmedEvent) { service.handle(event) }
```

It compiled, and the **happy path passed** — messages were consumed and marked `SENT`.

**Why it was wrong (subtly):**
With this Spring Kafka version, a `suspend` @KafkaListener **does not propagate handler
exceptions to the container's `DefaultErrorHandler`**. When the send failed, the exception was
swallowed: **no bounded retry, no publish to `order-confirmed.DLT`, and the offset was still
committed** (`AckMode.RECORD`) — the failed notification was silently lost. The integration test
proved it: the recoverer ran **0** times and only **1** delivery attempt occurred. This defeats
the entire resilience design (ADR-003): "no lost notifications, poison messages parked in the
DLT". A green happy-path test hid a broken failure path — exactly the kind of gap the money path
must not have.

**How it was caught:**
The DLT integration test (`OrderConfirmedDltIT`) asserted that an always-failing send lands in
`order-confirmed.DLT` and the row becomes `FAILED`. It timed out; debug logging showed the
recoverer never fired and there were no retries.

**How it was corrected:**
Switched to a non-`suspend` handler that bridges to the suspending service with `runBlocking`,
taking the raw `ConsumerRecord` (Spring Kafka's typed-payload conversion returned `KafkaNull` for
an already-deserialized value on a non-suspend method):

```kotlin
@KafkaListener(topics = ["order-confirmed"], containerFactory = "kafkaListenerContainerFactory")
fun onOrderConfirmed(record: ConsumerRecord<String, OrderConfirmedEvent?>) {
    val event = record.value() ?: return
    runBlocking { service.handle(event) }
}
```

The exception now surfaces synchronously → `DefaultErrorHandler` retries → DLT + `FAILED`.
The `runBlocking` exception to the `CLAUDE.md` rule was ratified by the team on 2026-07-11
(team-ratified, app PR #16): the consumer thread is a dedicated blocking poll loop, not a
reactive context, so blocking there is correct.

**Lesson learned:**
A passing happy-path test is not evidence the failure path works — for money-path handlers,
always test the failure/DLT/redelivery paths explicitly. Framework "it compiles and consumes"
does not imply "errors are handled"; verify exception propagation end-to-end.

---

## Case 13 — 2026-07-11 — DB env var names in the chart didn't match the app's contract (eurotransit-config)

**What the AI produced:**
`deploy/charts/eurotransit/templates/orders/deployment.yaml` wired the database connection
using Spring's conventional relaxed-binding names:

```yaml
- name: SPRING_DATASOURCE_URL
  value: "jdbc:postgresql://eurotransit-orders-db-rw...:5432/ordersdb"
- name: SPRING_DATASOURCE_USERNAME   # secretKeyRef → eurotransit-orders-db-app
- name: SPRING_DATASOURCE_PASSWORD
```

The manifest *looked* correct in isolation — a valid JDBC URL to the CloudNativePG `-rw`
service, credentials pulled from the operator secret via `secretKeyRef`, no plaintext.

**Why it was wrong:**
`orders-service/src/main/resources/application.yml` does **not** read `spring.datasource.*`.
It uses **R2DBC** at runtime and a **separate JDBC URL for Flyway** (Flyway is JDBC-only),
both behind **service-prefixed** placeholders with `localhost` defaults:

```yaml
spring.r2dbc.url:  ${ORDERS_DB_R2DBC_URL:r2dbc:postgresql://localhost:5432/ordersdb}
spring.flyway.url: ${ORDERS_DB_JDBC_URL:jdbc:postgresql://localhost:5432/ordersdb}
```

Because the chart set `SPRING_DATASOURCE_*` and the app never reads those keys, the injected
values were silently ignored and the app fell back to its `localhost:5432` default. Flyway
then failed with `Connection to localhost:5432 refused` and the pod crashlooped — while the
Deployment, Service, and secret all *appeared* healthy and correctly wired. Argo CD showed
`Synced` (the manifests matched Git) but `Degraded` (pods never went Ready), which is easy to
misread as a cluster problem rather than a config-contract mismatch. The same root cause
affects Notifications; Inventory has the reactive deps but no datasource config written yet.

**How it was caught:**
Investigating three crashlooping services (orders, inventory, notifications) on the AKS
cluster. Pod logs showed `localhost:5432` despite the pod env clearly containing the correct
`SPRING_DATASOURCE_URL`. Cross-referencing the app repo's `application.yml` revealed the env
var names the code actually binds — `ORDERS_DB_*`, not `SPRING_DATASOURCE_*`.

**How it was corrected:**
Renamed the env block in `orders/deployment.yaml` to the app's contract —
`ORDERS_DB_R2DBC_URL`, `ORDERS_DB_JDBC_URL`, `ORDERS_DB_USERNAME`, `ORDERS_DB_PASSWORD` —
with the R2DBC and JDBC URLs both built from `.Values.orders.db.{host,port,name}` and
credentials still via `secretKeyRef` on `eurotransit-orders-db-app`. Documented the DB
env-var contract in `CLAUDE.md` (Architecture constraints + naming table) and
`docs/agents/vojtech.md` so future chart edits don't reintroduce `SPRING_DATASOURCE_*`.

**Lesson learned:**
A manifest that is internally valid can still be wrong — the env var **names** are an API
contract owned by the application, not by Spring convention. When wiring config into a
service, verify the keys against the consuming code's `application.yml`, not against what the
framework *usually* calls them. `Synced + Degraded` with a `localhost` fallback in the logs
is the signature of injected config the app never reads.

---

## Case 14 — 2026-07-11 — chaos-mesh Application's chart repo not allowed by its AppProject (eurotransit-config)

**What the AI produced:**
The Chaos Mesh installation (ADR 0017, PR #31) declared the Argo CD Application under
`project: platform`, sourcing the chart from `https://charts.chaos-mesh.org`.

**Why it was wrong:**
Argo CD validates an Application's `source.repoURL` against its AppProject's
`sourceRepos`. The `platform` project (ADR 0011) allowed **only the config repo**, so the
Application was rejected at sync time with
`InvalidSpecError: application repo https://charts.chaos-mesh.org is not permitted in project 'platform'`.
The other six operators never hit this because they run under `project: default`, whose
`sourceRepos` is `*`. The agent adopted the platform-scoping intent without validating the
project's source constraints against an external chart source — the scoping model
constrains *sources*, not just destinations and resource kinds.

**How it was caught:**
At sync, by the delivery owner: the Application stuck `Unknown/InvalidSpecError` while the
other operators synced fine. He diagnosed the mismatch and proposed two options
(extend `platform.sourceRepos` vs fall back to `project: default`).

**How it was corrected:**
Option A — the pinned chart repo added to the platform project's `sourceRepos`
(`bootstrap/apps/projects.yaml`), keeping ADR 0017's deliberate platform-scoping intact;
the now-inaccurate "Both restrict sourceRepos to the config repo" comment updated; the
ADR 0017 consequence corrected (it wrongly claimed the required change was a CRD-group
allowance).

**Lesson learned:**
When an agent assigns an Application to a scoped AppProject, it must check the project's
`sourceRepos` (and destinations) against the Application's actual source. "More scoped"
projects fail closed: an external Helm repo needs an explicit, pinned entry.

---

## Case 15 — 2026-07-08 — Rebase conflict resolution silently reverted the `order-failed` compensation publish (eurotransit-app)

**What the AI produced:**
While rebasing the catalog AP-cache branch (app PR #17) — created before PR #16 (the
seat-release compensation) merged — the agent resolved the conflict on
`orders-service/.../config/KafkaErrorHandlingConfig.kt` by taking `--theirs`, i.e. its own
stale pre-#16 copy of the file.

**Why it was wrong (subtly):**
The #16 version's recoverer publishes `order-failed` when payment redeliveries are
exhausted; the stale copy only marked the order FAILED and logged. The result compiled,
CI stayed green, and #17 merged — but on `main` the seat-release compensation was **silently dead**:
Inventory's `OrderFailedConsumer` (also from #16) kept listening on a topic Orders no
longer published on exhaustion, so a failed order would keep its seats RESERVED forever.
No test failed, because the compensation path had no end-to-end test yet.

**How it was caught:**
By @marcodonatucci auditing the #17 merge: a catalog PR had touched an orders-service
config file, and diffing that file against the #16 version on `main` showed the
`order-failed` publish had disappeared.

**How it was corrected:**
App PR #18 restored the #16 version of `KafkaErrorHandlingConfig.kt` (recoverer publishes
`order-failed` on every exhaustion — safe on replay because the Inventory release is a
conditional, idempotent no-op), with ADR references aligned to the #17 renumbering.

**Lesson learned:**
A rebase conflict resolution is a semantic merge, and `--theirs`/`--ours` silently
discards the other side's working code — green CI cannot notice a feature that simply
vanished. After any agent-resolved rebase, diff the conflicted files against BOTH
parents; and treat "a PR touches a file outside its feature area" as a mandatory review
trigger.

---

## Case 17 — 2026-07-11 — `repository.save()` with app-assigned @Id: the entire write path was dead (eurotransit-app)

**What the AI produced:**
The persistence scaffolding for orders, inventory and payments: entities with
app-assigned identifiers (`Order` with a caller-generated UUID, `ProcessedEvent` /
`IdempotencyRecord` keyed by natural strings, `Reservation` / `PaymentIntent` with
`UUID.randomUUID()` defaults) persisted via `repository.save()`.

**Why it was wrong (subtly):**
Spring Data R2DBC decides INSERT-vs-UPDATE from the entity's state: a non-null @Id
with no `Persistable.isNew()` / `@Version` means "existing row" → `save()` issues an
UPDATE. Every new row therefore failed with `TransientDataAccessResourceException:
Row with Id ... does not exist` — order creation, every consumer's dedup row, seat
reservations, payment intents. Three services could not write AT ALL. Nothing looked
wrong: reads worked, conditional-UPDATE transitions (custom @Query) worked, the
catalog cache is in-memory, unit tests mock the repositories, CI was green — and the
code had just survived a four-auditor adversarial review that read it for *logic*,
not for framework persistence semantics. Notifications alone was immune, because its
repository used an explicit `@Query INSERT` from day one.

**How it was caught:**
By the FIRST real `POST /orders` ever sent through the gateway — a wiring check
during progressive-delivery demo preparation returned 500. Everything before that had exercised the
system via SQL seeds, reads, or unit tests.

**How it was corrected:**
App PR #20: `R2dbcEntityTemplate.insert()` at all 9 creation sites — explicit insert
semantics, no hand-written SQL, no entity surgery (Kotlin data class + `Persistable`
clashes with the generated `getId()`; `@Version` would need migrations on four
databases). Repositories remain for lookups and conditional transitions.

**Lesson learned:**
A green pipeline plus reviewed code proves the system *compiles and reasons well* —
not that it *runs*. Unit tests that mock the persistence layer cannot catch a
framework-semantics bug in the persistence layer itself; the only thing that could
have caught this earlier was one integration test (or one k6 smoke run) driving the
real write path. Send real traffic through the front door BEFORE declaring a
milestone "built" — and when one component (notifications) does the same thing
differently and its tests behave differently, treat the asymmetry as a signal, not
a style difference.

---

## Case 18 — 2026-07-11 — Kafka JSON type headers made every cross-service event undeliverable (eurotransit-app)

**What the AI produced:**
The Kafka serialization config of orders, inventory, payments and catalog:
`JsonSerializer` producers (which write the producer's OWN event class name into a
`__TypeId__` header by default) paired with consumers that either honoured that
header (orders/catalog, via the delegate `JsonDeserializer`) or used a naked
`JsonDeserializer` with no `ErrorHandlingDeserializer` at all (inventory/payments).

**Why it was wrong (subtly):**
Each service defines its own copy of the event classes in its own package — so the
header written by orders (`com.eurotransit.orders.event.OrderPlacedEvent`) is
unloadable in inventory. Two failure modes, both invisible from the outside:
inventory/payments crashed the consumer loop (`SerializationException`, container
stuck at the same offset); orders/catalog deserialized to `null`, which our own
poison-message guard dutifully ack'd and skipped — EVERY cross-service event was
silently dropped. Unit tests and the notifications ITs passed: within one service
(or one test JVM) the header class always loads. Combined with cases 17's layers,
the async pipeline had never delivered a single real cross-service event.

**How it was caught:**
Following ONE real order through the gateway after app #20/#21 restored writes: it
stuck in DRAFT; inventory's log showed the ClassNotFound loop on order-placed-1
offset 0 within a minute of looking.

**How it was corrected:**
App PR #22 — a uniform contract, yml-only: producers set
`spring.json.add.type.headers=false`; consumers set
`spring.json.use.type.headers=false` and rely on the
`spring.json.value.default.type` every @KafkaListener already declares;
inventory/payments additionally get `ErrorHandlingDeserializer` wrapping. This is
exactly what notifications' hand-built `KafkaConfig` had done all along
(`setUseTypeHeaders(false)`), which is why it was the only service whose consumer
ever worked.

**Lesson learned:**
Sharing a topic is sharing a CONTRACT, and a serializer default (type headers) is
part of that contract even when no one wrote it down. Per-service event-class
copies + default JsonSerializer headers are incompatible by construction; either
share the schema or strip the headers — decide explicitly, in one place. And when
one component (notifications) implements the same integration differently from the
other four, that asymmetry is a finding to investigate, not a style footnote — it
pointed at both case 17 and this one.

---

## Case 19 — 2026-07-11 — Two silent event-contract faults: frozen catalog cache and DLT'd notifications (eurotransit-app)

**What the AI produced:**
Catalog's cache-feeding listener (target type declared only in
`@KafkaListener(properties=...)`, direct-payload parameter) and notifications'
`OrderConfirmedEvent` with a REQUIRED `customerContact` field that no producer in the
system has ever sent.

**Why it was wrong (subtly):**
Both faults produced offsets that kept committing while nothing happened. Catalog:
the listener-level `spring.json.value.default.type` never reached the delegate
`JsonDeserializer` in production — every value deserialized to `null`, the payload
resolver rejected it, the error handler recovered, and the advisory cache froze at
its seed values while looking perfectly healthy. Notifications: orders publishes
`{orderId, timestamp}`; Jackson rejected every real payload for the missing required
field and routed it to the DLT — while the integration tests, which construct the
event class directly, stayed green.

**How it was caught:**
The FIRST live confirmed checkout (post cases 17/18): catalog still showed 100 seats
with 3 reserved in the inventory DB; the notifications log showed `Recovering to
DLT... valueType=null`. The catalog diagnosis was pinned by a test fed with bytes
captured verbatim from the topic: with the type in the consumer config they
deserialize; without it, exactly the null we saw.

**How it was corrected:**
App PR #23 — catalog's target type moved to `application.yml` (the tested path),
listener switched to the codebase-standard `ConsumerRecord<String, T?>` signature,
cache updates now log at INFO; notifications' `customerContact` defaults to a demo
contact until a customer identity exists on the producer side.

**Lesson learned:**
Closing the 17→18→19 trilogy: every fault in this chain was INVISIBLE from the
outside — green CI, committed offsets, healthy probes — and each fix peeled the next
fault into view. Cross-service event contracts need a single authoritative
definition (or contract tests against captured real payloads); "aligned by
convention" copies drift in fields, requiredness and config. And an advisory cache
that can fail silently must at least LOG when it applies an update — observability
of the happy path is what turns "frozen" into "obviously frozen".

---

## Case 20 — 2026-07-11 — p95 was unmeasurable: no histogram buckets behind every latency panel and alert (eurotransit-app)

**What the AI produced:**
The observability stack's latency layer: RED dashboard p95 panels, the
`CheckoutHighP95Latency` PrometheusRule and the canary-gate PromQL — all built on
`histogram_quantile(0.95, ... http_server_requests_seconds_bucket ...)` — while the
services' configuration never enabled `percentiles-histogram`, so Micrometer
published `http_server_requests_seconds` as a plain summary (count/sum/max) with NO
`_bucket` series at all.

**Why it was wrong (subtly):**
Everything rendered and deployed green: the dashboards showed empty p95 panels
(indistinguishable from "no traffic yet", which was also true), the alert loaded but
could never fire, and the gate query was simply `no data`. The queries and the
exposition format each looked correct in isolation; they had never been run against
each other with real traffic.

**How it was caught:**
During the LIVE canary gate: error-rate and split queries returned data, the p95
query returned nothing — with traffic demonstrably flowing. One targeted probe
(`http_server_requests_seconds_bucket` → 0 series) pinned it. The gate was assessed
from server-side max (32ms) + k6 client-side p95 (<120ms), both far inside the
300ms threshold.

**How it was corrected:**
App PR #24: `management.metrics.distribution.percentiles-histogram.http.server.requests=true`
on all five services, with SLO-aligned bucket boundaries (300 ms = the canary
promotion gate, 500 ms = the p95 SLO).

**Lesson learned:**
Repeats the mute-lag-alert lesson (#52) one layer deeper: it is not enough for a query's METRIC NAME
to exist — the metric's TYPE must support the function applied to it. Every
`histogram_quantile` needs `_bucket` series; verify by running the exact
dashboard/alert query against live exposition (`/api/v1/query`, not just
`/label/__name__/values`) before trusting a panel. A latency SLO you have never seen
move under traffic is a claim, not a measurement.

---

## Case 21 — 2026-07-12 — CE-5's injection was a switchover, not a crash (eurotransit-config)

**What the AI produced:**
The CE-5 runbook (drafted with the T5 batch, PR #37) prescribed the injection as a plain
`kubectl delete pod "$PRIMARY" --wait=false`, and suggested watching `status.currentPrimary`
for the promotion timestamp.

**Why it was wrong (subtly):**
`kubectl delete pod` is **graceful**: SIGTERM → the CNPG instance manager enters *smart
shutdown* (`spec.smartShutdownTimeout`, our default **180 s**), during which established
connections keep working — and Orders' R2DBC pool held established connections. In Run 1 the
"killed" primary **kept serving checkout writes for 3 minutes** while the cluster phase said
"Failing over"; the only outage was a 3.17 s blip when the smart window expired. The runbook
was therefore measuring the *maintenance/switchover* path while claiming to test *failure* —
and an operator trusting `status.currentPrimary` (which lagged the data plane by ~4 s, and in
Run 1 flipped only at T0+185 s) would have concluded "failover takes 3 minutes, RTO blown"
when in fact **checkout availability never materially degraded at all**.

**How it was caught:**
Running it (CE-5 Run 1, 2026-07-12): the ack harness showed writes flowing continuously
through a pod that had been "deleted" 2 minutes earlier — steady state never broke, so the
recovery measurement was meaningless. `spec.smartShutdownTimeout: 180` matched the observed
delay exactly.

**How it was corrected:**
Method updated to `--grace-period=0 --force` (SIGKILL — also what Chaos Mesh `pod-kill`
delivers), and the runbook now instructs taking RTO from the **ack log**, never from the CR
status field. Run 2 with SIGKILL measured the real thing: 16.65 s write outage, RPO = 0.
Both runs recorded in `ce-5-cnpg-failover-run-1.md`.

**Lesson learned:**
An injection must reproduce the failure mode in the hypothesis — a graceful delete is a
*controlled shutdown*, categorically different from a crash. Before trusting any recovery
measurement, verify the steady state actually BROKE (a chaos run where nothing degrades is a
scoping bug until proven otherwise, cf. Case CE-1/Run-1). And operator status fields are
control-plane views: time recovery from the data plane (the requests), not the CRD.

## Case 22 — 2026-07-14 — Kafka SASL helper referenced a `username` secret key Strimzi never generates (eurotransit-config)

**What the AI produced:**
The `eurotransit.kafkaSaslEnv` Helm helper (PR #95, Feature/kafka auth) wired SCRAM-SHA-512
credentials into the services by pulling `KAFKA_USER` and `KAFKA_PASS` from the KafkaUser
secret via `secretKeyRef` (keys `username` / `password`) and assembling the JAAS string with
Kubernetes `$(VAR)` substitution.

**Why it was wrong (subtly):**
Strimzi SCRAM-SHA-512 user secrets contain exactly two keys: `password` and
`sasl.jaas.config`. There is **no `username` key** — the SCRAM username is the KafkaUser's
`metadata.name` itself. The manifest was schema-valid, so `helm lint`, `helm template`, and
kubeconform all passed; the secret-key contract is only checked by the kubelet at container
creation. The rollout wedged silently: every new ReplicaSet pod across all five services sat
in `CreateContainerConfigError` (`couldn't find key username in Secret
eurotransit/eurotransit-orders`) while the pre-#95 pods kept serving — Argo CD "Synced but
Degraded", exactly the state the delivery-owner doc flags as a deployment failure.

**How it was caught:**
Argo CD health went Degraded ~20 min after the #95 merge; `kubectl describe pod` on a stuck
pod showed the missing-key event, and `kubectl get secret eurotransit-orders -o json`
confirmed the secret's actual keys (`password`, `sasl.jaas.config`) with `ownerReferences:
KafkaUser`.

**How it was corrected:**
Issue #97; helper rewritten to mount Strimzi's ready-made `sasl.jaas.config` key directly
into `SPRING_KAFKA_PROPERTIES_SASL_JAAS_CONFIG`, dropping the `KAFKA_USER`/`KAFKA_PASS`
indirection entirely — one secretKeyRef instead of two, and no string assembly to get wrong.

**Lesson learned:**
Operator-generated secrets have a *contract*, not a guessable shape — the AI pattern-matched
"credentials secret ⇒ username + password keys" (true for CloudNativePG `-db-app` secrets,
false for Strimzi KafkaUsers). Offline gates cannot catch a wrong secret key; when a template
consumes an operator-generated secret, verify the actual key names against the operator's
docs or a live secret before merging. Prefer consuming ready-made keys (Strimzi ships the
full JAAS string) over reassembling credentials in the pod spec.

---

## Case 23 — 2026-07-16 — USE replica panel hid split kube-state-metrics histories behind one legend name (eurotransit-config)

**What the AI produced:**
The USE dashboard queried `kube_deployment_status_replicas_ready` and
`kube_deployment_spec_replicas` directly, then formatted every result using only
`{{deployment}} ready` or `{{deployment}} desired`.

**Why it was wrong (subtly):**
Prometheus series identity includes scrape-target labels such as `instance`, `pod`,
`service`, and `endpoint`. When kube-state-metrics restarts or its scrape target changes,
one logical Deployment can therefore have multiple historical series fragments. Grafana
rendered those fragments with the same legend text because the alias omitted the differing
labels. The combined graph could show `eurotransit-catalog ready = 0`, while clicking that
legend selected a different fragment and displayed a constant 2 across its own history.
Neither view explained that several physical time series were masquerading as one logical
series.

**How it was caught:**
A human compared the unfiltered panel with the legend-isolated
`eurotransit-catalog ready` series: the former contained a zero-replica interval, while
the latter showed two ready replicas for the whole selected window. Inspecting the JSON
showed raw kube-state-metrics queries with no aggregation and deployment-only aliases.

**How it was corrected:**
Both gauges now use `max by (deployment) (...)`, collapsing scrape-target fragments into
exactly one logical ready and desired series per Deployment at each evaluation point. The
panel uses stepped, integer rendering because replica gauges change discretely rather than
continuously.

**Lesson learned:**
A Grafana legend alias is presentation, not aggregation. If a panel intentionally hides
labels that participate in Prometheus series identity, the PromQL must first reduce those
labels explicitly. For Kubernetes object-state gauges, verify that one logical object
produces one query result across exporter restarts; otherwise legend filtering can change
the apparent history and turn a diagnostic dashboard into contradictory evidence.

---

## Case 25 — 2026-07-16 — `order.id` trace tag and Kafka producer spans silently detached at coroutine suspension points (eurotransit-app)

**What the AI produced:**
`OrderTraceTagger` (orders-service, shipped in image `9b4c9a0` together with the
"Trace an order" dashboard): tag the active checkout span with the searchable
`order.id` attribute via `tracer.currentSpan()?.tag(...)`, called from
`OrderService.placeOrder`. Unit tests mocked the `Tracer` and passed; the change
merged with the dashboard whose whole premise is searching Tempo for that attribute.

**Why it was wrong (subtly):**
Micrometer's `tracer.currentSpan()` and KafkaTemplate's observation support read a
**ThreadLocal**, but both call sites sit past a suspension point
(`findByIdempotencyKey`, a suspending R2DBC lookup). A WebFlux coroutine resumes on
an arbitrary thread after suspension, so the ThreadLocal is empty there: the
`?.`-guarded tag was a silent no-op, and every `kafkaTemplate.send` on an HTTP-origin
path found no current parent and **rooted a brand-new trace**. Nothing failed —
spans kept flowing to Tempo, dashboards stayed green, and the unit test recreated
exactly the state production lacked (the mock returned a span unconditionally).
The breakage even looked random: the mid-pipeline Kafka chain stayed correctly
linked, because the consumers' non-suspend `runBlocking` bridge (case 12,
app ADR-004) pins every continuation to the listener thread, where the container's
ThreadLocal observation scope survives. Only the two HTTP-origin steps (Orders
checkout, Payments authorize) detached.

**How it was caught:**
Testing the new dashboard: searching `{ span.order.id = "<uuid>" }` returned nothing
for a freshly created order. Querying the Tempo API directly showed both symptoms:
the `http post /orders` span carried no `order.id` attribute, and `order-placed send`
/ `payment-authorized send` spans were **roots of their own traces** — with the full
downstream waterfall (inventory receive → inventory-reserved send → …) attached to
the detached root instead of the checkout span. The handout review had predicted the
failure mode before it was confirmed live ("the active span may be lost across the
coroutine boundary, causing tagging to silently do nothing").

**How it was corrected:**
The request Observation travels in the **Reactor context**, which
kotlinx-coroutines-reactor carries with the coroutine (`ReactorContext`) — unlike the
ThreadLocal, it survives suspension. New `CoroutineTraceContext` helpers in orders and
payments (app-repo branch `fix/order-trace-context-propagation`):
`currentRequestObservation()` reads the Observation from
`coroutineContext[ReactorContext]`; the tag becomes
`observation.highCardinalityKeyValue("order.id", …)`, copied onto the server span when
the observation stops; `withRequestObservation { }` re-opens the observation scope
around `kafkaTemplate.send` so producer spans parent to the request trace. The
ThreadLocal path is kept as fallback so the `runBlocking` listeners keep working
unchanged. Unit tests now cover the ReactorContext path, including asserting the
ThreadLocal is *not* consulted when the observation is present.

**Lesson learned:**
In a coroutine WebFlux service, any ThreadLocal-based instrumentation —
`tracer.currentSpan()`, observation-aware templates — silently stops working past the
first suspension point; the context that travels with the coroutine (the Reactor
context) is the only reliable carrier. Two verification rules follow. First, a
`?.`-guarded tagging call is untestable with a mock of the ThreadLocal holder: the
mock manufactures the exact state production is missing, so the test proves nothing
about propagation. Second, verify tracing claims against the trace store — search for
the attribute, walk one trace end to end — not against "spans are being exported":
export kept working the whole time while every trace was quietly split in two.

---

## Case 26 — 2026-07-16 — `SimpleMailMessage.apply { setFrom(from) }` sent every email with a null sender (eurotransit-app)

> Caught by a unit test while adding the real SMTP sender (optional per-order
> `customerContact` threaded checkout → `order-confirmed` → Notifications).

**What the AI produced:**
The new `SmtpEmailSender` took the sender address as a constructor property named `from` and
built the message with:

```kotlin
class SmtpEmailSender(
    private val mailSender: JavaMailSender,
    registry: MeterRegistry,
    @Value("\${notifications.email.from:...}") private val from: String,
) : EmailSender {
    override suspend fun send(event: OrderConfirmedEvent) {
        val message = SimpleMailMessage().apply {
            setFrom(from)              // intended: the constructor's `from`
            setTo(event.customerContact)
            ...
        }
        withContext(Dispatchers.IO) { mailSender.send(message) }
    }
}
```

**Why it was wrong (subtly):**
Inside `apply {}` the receiver is the `SimpleMailMessage`, which exposes a JavaBean `from`
property (`getFrom`/`setFrom`). Kotlin resolved the unqualified `from` to **the receiver's
own property** (`this.from`, null at that point) rather than the outer class's constructor
param — so `setFrom(from)` became `setFrom(null)`. `setTo(event.customerContact)` was
unaffected because `event` is not a member of `SimpleMailMessage`, so recipients looked
correct while the sender was silently null. It compiled cleanly with no warning.

**How it was caught:**
The sender's unit test captured the built `SimpleMailMessage` (mockk `slot`) and asserted
both fields. The recipient assertion passed; the sender assertion failed —
`expected: <noreply@eurotransit.test> but was: <null>` — pointing straight at the shadowing.

**How it was corrected:**
Renamed the constructor param to `fromAddress` (and the test's named argument) so the
unqualified reference inside `apply {}` can no longer collide with a bean property of the
receiver.

**Lesson learned:**
`apply {}`/`with {}` put a foreign object's properties into unqualified scope; when the
receiver is a JavaBean, its setters imply same-named readable properties that shadow outer
names. Prefer a param name that cannot collide with the receiver's properties (or qualify
with `this@Outer.`), and always assert *every* field a builder sets — the bug hid behind a
correct-looking neighbouring field.
