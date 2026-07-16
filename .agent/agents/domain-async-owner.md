# Agent: @Lollegro — Domain & Async Owner

## Scope

Primary ownership of:
- **Service boundaries** and decomposition of the five backend services (orders, inventory, payments, notifications, catalog) — which calls are synchronous, which are event-driven, and why
- **The async pipeline**: Kafka event topology on the money path (`order-placed` → `inventory-reserved` → sync authorize → `payment-authorized` → `order-confirmed`), event contracts, consumer-group semantics
- **Kotlin coroutines / structured concurrency**: coroutine scopes as failure domains, cooperative cancellation, backpressure
- **Shutdown semantics**: the `GracefulShutdownManager` pattern (orders/inventory/payments), SIGTERM drain, readiness flip, the 5/45/50/60 timeout chain
- **Chaos experiment CE-4** (network partition / Kafka disruption): hypothesis "pipeline recovers; nothing lost or duplicated after healing"

Cross-cutting awareness (not primary owner, but must understand end-to-end):
- Idempotency stores and the "never oversell" invariant (owner: Data & Consistency, @MauroC0l) — my consumers depend on them
- Kafka wiring: `KafkaTopic` CRs, Strimzi, bootstrap config (owner: Delivery, @vojtech-n) — I confirm consumer group IDs and offsets when topics change
- Resilience4j policy values on the Orders → Payments call (owner: Resilience) — the call site and its place in the pipeline are mine, the numeric knobs are not
- Consumer-lag / DLT-depth metrics and alerts (owner: Observability) — they are the visibility layer over my pipeline

---

## Decisions made

### Synchronous payment authorization (config ADR 0018, team vote 2026-07-11)
**Decision:** `Orders → Payments` (`POST /payments/authorize`, `Idempotency-Key = orderId`) is the **only** synchronous cross-service call on the money path, wrapped in a Resilience4j circuit breaker + bounded retry + dedicated connection pool. Everything else stays Kafka-driven.
**Rationale:** the capstone spec requires breakers on synchronous calls and CE-1 was not demonstrable with a fully Kafka pipeline; "synchronous only where a decision is needed *now*" — whether the money is authorized is such a decision. Consequence: Payments has **no** `@KafkaListener`; it only produces `payment-authorized`. There is no `PAID` order state.

### EM-25 as the canonical Orders base (app ADR 0005)
**Decision:** the convergence vote picked EM-25 (idempotent base) as canonical; EM-19 was deleted and the EM-21 goals (lifecycle/saga) were re-implemented on top. Legacy EM-21 files were removed at merge.
**Rationale:** three divergent Orders implementations could not coexist (duplicate controllers, duplicate consumers on the same topic, two entities on one table). EM-25 already had the idempotency machinery.

### Idempotent consumer pattern (app ADR 0005)
**Decision:** every money-path Kafka handler does a read-before-write check on `processed_events` (key `{orderId}:{eventType}`), business write + dedup insert in **one** transaction, downstream publish **outside** the transaction.
**Rationale:** at-least-once + dedup makes a redelivered event a no-op; the publish is redone idempotently on redelivery. This is the A↔B pillar coupling: shutdown correctness comes from at-least-once + dedup, not from forbidding cancellation.

### Graceful shutdown pattern (app ADR 0005 + em25+21 notes)
**Decision:** `GracefulShutdownManager` as a `SmartLifecycle` bean (`getPhase() = Int.MAX_VALUE` — highest phase stops **first**), copied per service into orders/inventory/payments:
1. `stop(callback)` flips readiness via `AvailabilityChangeEvent.publish(REFUSING_TRAFFIC)` → actuator returns 503 → K8s removes the pod from endpoints;
2. drain loop polls an `AtomicInteger` in-flight counter (500 ms) with a **45 s budget** (5 s margin inside Spring's 50 s phase timeout; chain `preStop(5s) + Spring(50s) < terminationGracePeriod(60s)` → no SIGKILL during an orderly drain);
3. consumers guard with `isAcceptingTraffic()`: during drain, new messages get an **early return without ack** → offset uncommitted → rebalanced to a healthy instance (not lost, not double-processed);
4. `coroutineContext.ensureActive()` sits **between** the DB transaction and the downstream publish — the one point where cancellation is both safe (data committed) and useful (publish redone idempotently).
**Rationale (alternatives rejected):** `@PreDestroy`/`DisposableBean` fire too late with no ordering control; a custom health flag reinvents Spring's native availability mechanism; `Semaphore`/`CountDownLatch` don't fit a count-only need; nack/exception on drain would trigger pointless local retries.

### Copy per service, no shared Gradle module (team decision, task25)
**Decision:** `GracefulShutdownManager` is duplicated in orders/inventory/payments rather than extracted to `backend/common`.
**Rationale:** ~60 lines; existing convention (`ProcessedEvent*` is already duplicated); zero build coupling between independently deployable services; timeouts can diverge deliberately. Revisit only if a third copy-drift bug appears.

### Catalog and Notifications: no shutdown manager
**Decision:** both get only `server.shutdown: graceful`.
**Rationale:** Catalog is a stateless read surface (WebFlux drains HTTP natively); Notifications is redelivery-safe by design (dedup + DLT, ADR 0001–0003). Neither has the consumer→transaction→publish pattern that needs coordination.

### Notifications topology and failure handling (app ADR 0001–0003, drafted by @marcodonatucci, ratified)
**Decision:** Notifications consumes `order-confirmed` only (`notification-requested` stays reserved, not wired); dedup in a dedicated PostgreSQL store with a two-phase `PENDING → SENT` row; manual ack, bounded retry → `order-confirmed.DLT`; own-DB outage → block-and-lag.
**Rationale:** one authoritative fact, no dual-write/outbox on Orders; "at most one email per order" survives restart and rebalance; a poison message must not head-of-line-block the pipeline; Notifications is off the critical path so growing lag never affects checkout.

### runBlocking bridge in @KafkaListener (ratified by team vote, 2026-07-11)
**Decision:** listeners that need error-handler semantics are **non-suspend** handlers taking the raw `ConsumerRecord` and bridging to the suspending service with `runBlocking`. In use in `OrderConfirmedListener`, `InventoryReservedConsumer`, `OrderFailedConsumer`.
**Rationale:** suspend `@KafkaListener`s swallow handler exceptions in this Spring Kafka version, so retries/DLT never fire (agent-log Case 12). The consumer thread is a dedicated blocking poll loop, so blocking there is correct. This is the **one sanctioned exception** to the "no runBlocking outside bootstrap" rule.

### Catalog AP cache (app ADR 0006/0007, awareness)
**Decision:** Catalog serves browsing from an in-memory advisory cache fed by `inventory-reserved` (per-instance consumer group, no dedup), hydrated at startup from an Inventory snapshot (`GET /inventory/routes`) and consuming from `latest`.
**Rationale:** the CP/AP contrast becomes demonstrable in code; replay-from-earliest diverged permanently after out-of-band reseeds (issue #31) — the snapshot is authoritative state, events are deltas.

---

## Constraints and invariants

**Do NOT change without discussing with me:**

1. **Every Kafka consumer handler must be idempotent.** No consumer is merged without a dedup strategy (or an explicit, documented exemption like Catalog's advisory cache).
2. **The event topology is fixed**: `order-placed` → `inventory-reserved` / `order-failed` → (sync authorize) → `payment-authorized` → `order-confirmed` (+ `order-confirmed.DLT`). New topics or consumers on money-path topics go through me.
3. **Payments consumes nothing from Kafka.** It is reached only by the synchronous authorize call and only produces `payment-authorized`. Do not add a `@KafkaListener` to it.
4. **The transaction/publish split**: dedup insert + business write in one transaction, publish outside, `ensureActive()` in between. Do not move the publish inside the transaction or add an outbox without a superseding ADR.
5. **The shutdown timeout chain** `preStop(5s) + Spring(50s) < terminationGracePeriod(60s)` and the 45 s drain budget. Changing any value requires re-verifying the whole chain (config ADR 0002 mirrors it in the chart).
6. **No `GlobalScope`; every `CoroutineScope` is a failure domain. No `runBlocking` on the main path** — the only sanctioned exception is the ratified `@KafkaListener` bridge.
7. **Order states are `DRAFT | RESERVED | CONFIRMED | FAILED`**, stored as `VARCHAR(50)`. Do not reintroduce `PAID` or the `order_status` PG enum (dropped in V3 for R2DBC codec friction).
8. **Early-return-without-ack is the only drain behaviour** for guarded consumers — no nack, no exception, no ack-then-skip.

---

## How to contribute to my area

### Adding or changing a Kafka consumer
- Wrap handling in the idempotent pattern (constraint 4); key `{orderId}:{eventType}` unless you have a documented reason (see Payments/Notifications/Catalog exceptions in `.agent/context/money-path.md`)
- Use the non-suspend `ConsumerRecord` + `runBlocking` bridge if you need error-handler/DLT semantics
- Add the `isAcceptingTraffic()` guard and in-flight tracking if the service has the shutdown manager
- Update `.agent/context/kafka-topics.md` **and** `money-path.md` in the same PR; confirm consumer group ID with me

### Adding a topic
1. `KafkaTopic` CR in config-repo `kafka/kafka-topics.yaml` (`apiVersion: kafka.strimzi.io/v1`, ADR 0014) — coordinate with Delivery
2. Producer/consumer table + money-path doc updated in the same PR
3. Consumer group and offset-reset semantics agreed with me (money-path consumers: shared group, manual ack; cache consumers: per-instance group)

### Touching shutdown code
- Never change one copy of `GracefulShutdownManager` without checking whether the fix applies to all three
- Any timeout change re-verifies the 5/45/50/60 chain end-to-end (app config + Helm values)
- The drain must remain demonstrable: readiness refuses during drain, in-flight completes, no orphan tasks, no double-processing

### Review checklist for PRs touching my area
- [ ] New/changed consumers are idempotent and documented in `money-path.md`
- [ ] No `GlobalScope`, no unsanctioned `runBlocking`, cancellation stays cooperative
- [ ] Publish stays outside the DB transaction; `ensureActive()` placement untouched
- [ ] Topic changes come with the CR + both context docs in the same PR
- [ ] Shutdown guard (`isAcceptingTraffic()` + in-flight tracking) present where the manager exists

---

## Open questions

- **App ADR 0005 ratification** — pre-merge conditions are closed in code (publish gated on `updated == 1`, phase comment fixed, EM-21 legacy deleted); the ADR is still Proposed and needs the formal team vote.
- **CE-4 (network partition / Kafka disruption)** — my experiment, not yet run: steady-state SLI, partition injection via Chaos Mesh, verify nothing lost/duplicated after healing; report in `docs/chaos/CE-4.md`.
- **SIGTERM drain demo** — must be demonstrated for the M2/Pillar A DoD (kill a pod mid-flow, show no orphaned work and no double-processing on dashboards), not just asserted.
- **`notification-requested`** — stays reserved/not wired (app ADR 0001); a future notification channel needs a superseding ADR.
- **Pillar A written analysis** — "where async reduces costs, where it doesn't (CPU-bound)" still to be written for the DoD.

---

## Useful context for AI

When generating artifacts in this area, the following context is fixed and must not be changed:

### Money path (authoritative trace)
See `.agent/context/money-path.md` — steps 1–7 are the SLO-critical path; Notifications is out of the success criterion. Order states: `DRAFT → RESERVED → CONFIRMED`, or `→ FAILED` with seat-release compensation. No `PAID` state.

### Idempotency keys (per service)
- Orders, Inventory: `{orderId}:{eventType}` in each service's own `processed_events`
- Payments: `{orderId}:payment` on the `payment_intents.idempotency_key` unique index (its `processed_events` table is unused — do not model new consumers on it)
- Notifications: `sent_notifications` keyed by `order_id`, two-phase `PENDING → SENT`
- Catalog: no dedup by contract (advisory AP cache)

### Consumer handler skeleton (money-path services)
```kotlin
@KafkaListener(topics = ["inventory-reserved"], groupId = "orders")
fun onInventoryReserved(record: ConsumerRecord<String, InventoryReservedEvent>, ack: Acknowledgment) {
    if (!shutdownManager.isAcceptingTraffic()) return   // early return, NO ack → rebalance
    runBlocking {                                        // sanctioned bridge (ADR 0004 note)
        shutdownManager.trackInflight {
            // 1. dedup check + business write + processed_events insert — ONE transaction
            // 2. coroutineContext.ensureActive()  ← between TX and publish
            // 3. downstream publish (idempotent on redelivery)
        }
    }
    ack.acknowledge()
}
```

### Shutdown chain (fixed values)
`preStop sleep 5s` (chart) → SIGTERM → readiness `REFUSING_TRAFFIC` → drain in-flight, 45 s budget → Spring phase timeout 50 s → `terminationGracePeriodSeconds: 60`. Manager phase: `Int.MAX_VALUE` (stops first, containers still polling, guard rejects new work).

### Kafka fixed names
Cluster `eurotransit-kafka`; bootstrap `eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092`; topics per `.agent/context/kafka-topics.md` (CRs only, auto-create disabled, `kafka.strimzi.io/v1`).
