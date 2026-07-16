# Capstone Definition of Done

Reviewed like any PR (single approval — ADR 0019); changes to the DoD should still be discussed by the whole team.

**Status pass: 2026-07-15** — boxes ticked against evidence (linked inline). All five chaos
experiments now have executed PASS runs; their conclusions are drafts pending team
ratification (ADR 0019). Remaining open runway: conclusion ratification, the recorded demo,
the postmortem, and the live presentation.

## Pillar A — Distributed design and async execution
- [x] Service decomposition documented with explicit sync/async boundaries and justification — `docs/design/service-boundaries.md`
- [x] Order pipeline implemented with Kotlin coroutines / Flows — suspend handlers across all five services; `DRAFT → RESERVED → CONFIRMED/FAILED` via Kafka stages
- [x] Structured concurrency: one CoroutineScope per failure domain — app-repo `GracefulShutdownManager` + suspend listeners per service (app ADR 0005)
- [x] Cooperative cancellation on SIGTERM demonstrated (no orphaned tasks, no double-processing) — `GracefulShutdownManagerTest` (app repo); drain chain invariant in `values.yaml` (ADR 0002); re-demonstrated live under chaos (CE-2 runs 2–3, CE-3 run 2: no lost/duplicated work across pod kills and node drains)
- [x] Readiness flips to refusing traffic while in-flight work drains — `AvailabilityChangeEvent → REFUSING_TRAFFIC` before the 45 s drain, consumers skip-without-ack
- [x] Written analysis: where async reduces cost in EuroTransit and where it would not help — `docs/design/service-boundaries.md` §"Async cost analysis"

## Pillar B — Consistency under contention
- [x] Consistency model chosen and justified using CAP/PACELC terms — `docs/design/consistency.md` (Inventory CP/PC-EC vs Catalog AP/EL, per-resource justification)
- [x] Inventory reservation implemented (conditional/atomic in PostgreSQL or state machine) — atomic conditional UPDATE + optimistic lock with bounded retry + `UNIQUE(order_id, route_id)`
- [x] Idempotency keys implemented across the full money path — `processed_events` per consumer (same-transaction), HTTP `Idempotency-Key` on `POST /orders`; idempotent replay verified live 2026-07-11 (200 + cached body)
- [x] Deduplication scheme documented in docs/design/idempotency.md
- [x] Chaos experiment proves "never oversell" invariant holds under duplicate messages and Pod death — **CE-2 runs 2 (2026-07-12) + 3 (2026-07-13, independent reproduction): PASS** — pod killed with 224 reservations in flight; I1/I2 invariants held, 500 seats = 500 CONFIRMED = 500 payment intents, 0 oversell, 0 double-charge (`ce-2/ce-2-pod-kill-inventory-run-3.md`)

## Pillar C — Resilience engineering
- [x] Circuit breakers on Orders → Payments with open/half-open policy and defined fallback — ADR 0018; Resilience4j in `PaymentsClient` (app), fallback = queued Kafka redelivery, order stays RESERVED
- [x] Bulkheads: isolated resource pools per flow — dedicated bounded connection pool for the Payments call (`PaymentsWebClientConfig`, app)
- [x] Bounded retries with backoff and jitter on every remote call — retry 3× exponential + `randomizedWaitFactor` (app `application.yml`); Kafka `ExponentialBackOff` on redelivery
- [x] Backpressure / load shedding (HTTP 429) under overload — RateLimiter on `POST /orders`, `timeoutDuration: 0` (refuse, don't queue); 429 excluded from the SLO error budget by ratified decision
- [x] Notifications failure does not fail checkout — terminal Kafka-only consumer, DLT + durable dedup (app ADR-001..004)
- [x] Meaningful startup / readiness / liveness probes (liveness does NOT check downstream) — shared probe block in `values.yaml`, liveness = local process only
- [x] PodDisruptionBudgets on all critical-path services — `templates/shared/pdb-*.yaml` (all five) + topology spread (ADR 0023)

## Pillar D — Delivery, observability, proof
- [x] GitOps delivery: CI updates config-repo; Argo CD reconciles; CI holds no cluster credentials — ACR via OIDC (ADR 0010), write-back via GitHub App token (ADR 0007); `eurotransit-gitops-writeback[bot]` commits in the history are the proof
- [x] Canary demonstrated via TraefikService: small fraction → watch SLIs → promote or abort — PRs #58/#59, ratified gate held (10.06 % split, 0 % 5xx, p95 ≪ 300 ms), promoted; `docs/delivery/2026-07-11-progressive-delivery-demo-results.md`
- [x] Blue/green demonstrated: stand up new version → switch traffic → fast rollback available — PRs #61/#62/#63 on Catalog, atomic IngressRoute cutover, 5-clean-minute window, one-commit rollback by construction
- [x] DORA strategy discussion: where rolling and all-at-once would fit, why not used on critical path — ADR 0026 §"DORA delivery strategies"
- [x] Per-service RED dashboards in Grafana — `dashboards/red-money-path.json` (GitOps-delivered, PR #33)
- [x] Checkout SLO overview dashboard — `dashboards/slo-overview.json` (success, p95, remaining-budget proxy, 5 m / 1 h / 6 h burn state; current 7-day Prometheus evidence is explicitly not presented as 30-day compliance)
- [x] Async order-lifecycle dashboard — `dashboards/order-lifecycle.json` (accepted → authorized → notified convergence, per-topic lag, resilience state, Tempo trace drill-down; exact DB state counts remain an app-instrumentation follow-up)
- [x] Exact order trace lookup — `dashboards/order-trace.json` + trace-only `order.id` span attribute in Orders (order ID → matching Tempo trace → embedded end-to-end waterfall)
- [x] USE / infrastructure / Golden Signals dashboard — `dashboards/use-infrastructure.json`
- [x] Symptom-based alerts tied to SLOs (burn rate / user-visible symptoms, not CPU) — multi-window burn-rate rules (14× page / 6× ticket), CPU only as non-paging capacity ticket (PR #36)
- [x] Latency SLO and success-rate SLO for checkout defined with SLIs and error-budget statement — `docs/design/slo-definitions.md`, team-ratified 2026-07-11, incl. deploy-freeze policy
- [x] Distributed tracing across the money path — Tempo + OTLP (ADR 0022), W3C trace context propagated through Kafka (app PR #14), searchable by exact order ID

## Chaos experiments

*All five executed with PASS runs (2026-07-12 → 2026-07-14), each with whole-database
reconciliation against the k6 client-side count. **Conclusions are drafts pending team
ratification (ADR 0019)** — ratify before the live presentation.*

- [x] Latency injection → Payments: circuit breaker opens, fallback engages, Catalog unaffected — **runs 4 + 5 (2026-07-13, independent reproduction): PASS** — breaker OPEN ≤ T0+35 s, ~84 fast-fail not-permitted calls, Catalog flat, queued backlog drained on recovery, exact reconciliation 2415 = 2413 CONFIRMED + 2 FAILED, 0 double charges (`ce-1/ce-1-latency-payments-run-5.md`)
- [x] Pod kill → Inventory mid-reservation: idempotency prevents oversell/double-charge — **runs 2 + 3: PASS** — see Pillar B item above (`ce-2/ce-2-pod-kill-inventory-run-3.md`)
- [x] Node/AZ disruption: PDBs and topology spread keep critical path available — **run 2 (2026-07-13): PASS** after the run-1 capacity fix — node drained, checkout lost 1/12,448 requests (0.008 %), 3889 = 3889 reconciled, Kafka PDB sequenced broker evictions (`ce-3/ce-3-node-disruption-run-2.md`; run 1 FAILED and drove the capacity change — that finding is part of the evidence)
- [x] Kafka partition: async pipeline recovers, nothing lost or duplicated — **run 1: PASS** — idempotent producer retried to the new leader, 0 failed of 20,371 requests, 6365 = 5000 CONFIRMED + 1365 FAILED, nothing lost, nothing duplicated (`ce-4/ce-4-kafka-partition-run-1.md`)
- [x] CloudNativePG primary failover: observed impact on checkout, recovery within stated RTO — **run 1 (2026-07-12) + run 3 (2026-07-14, independent reproduction): PASS — RTO 16.8 s / 17.3 s ≤ 60 s, RPO 0 (1021 acked = 1021 CONFIRMED)**, all failures bounded, breaker stayed CLOSED (`ce-5/ce-5-cnpg-failover-run-3.md`)
- [x] Each experiment has: hypothesis, steady-state definition, observations, conclusion, changes made — complete for all five; **conclusions are drafts pending team ratification (ADR 0019)**

## Agentic coding
- [x] Threat-model paragraph for the coding agent committed in docs/ — [`ai-threat-model.md`](ai-threat-model.md) (canonical; summarized in `CLAUDE.md`)
- [x] docs/agent-log.md contains at least three caught-and-corrected agent mistakes — **22 cases** as of 2026-07-14
- [ ] Team can explain, defend, and operate everything that was built — claimed and validated at the live presentation

## Deliverables
- [x] Application repository with history showing GitOps-driven delivery
- [x] Configuration repository with history showing GitOps-driven delivery
- [ ] docs/ containing all required documents — everything present except the postmortem, which is a template until the live-incident scenario runs
- [ ] Recorded demo (~5 min) committed as a link — chaos runs done; recording plan drafted in `docs/demo-recording-handout.md` (must include an alert firing under injected failure)
- [ ] Live presentation scheduled — chaos runs are done; contact the teaching staff
