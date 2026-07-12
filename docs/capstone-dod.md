# Capstone Definition of Done

Reviewed like any PR (single approval — ADR 0019); changes to the DoD should still be discussed by the whole team.

**Status pass: 2026-07-12** — boxes ticked against evidence (linked inline). Unchecked items
are the open runway: the five chaos runs, the recorded demo, the postmortem, and the live
presentation.

## Pillar A — Distributed design and async execution
- [x] Service decomposition documented with explicit sync/async boundaries and justification — `docs/design/service-boundaries.md`
- [x] Order pipeline implemented with Kotlin coroutines / Flows — suspend handlers across all five services; `DRAFT → RESERVED → CONFIRMED/FAILED` via Kafka stages
- [x] Structured concurrency: one CoroutineScope per failure domain — app-repo `GracefulShutdownManager` + suspend listeners per service (app ADR 0005)
- [x] Cooperative cancellation on SIGTERM demonstrated (no orphaned tasks, no double-processing) — `GracefulShutdownManagerTest` (app repo); drain chain invariant in `values.yaml` (ADR 0002); live re-demonstration comes free with CE-2/CE-3
- [x] Readiness flips to refusing traffic while in-flight work drains — `AvailabilityChangeEvent → REFUSING_TRAFFIC` before the 45 s drain, consumers skip-without-ack
- [x] Written analysis: where async reduces cost in EuroTransit and where it would not help — `docs/design/service-boundaries.md` §"Async cost analysis"

## Pillar B — Consistency under contention
- [x] Consistency model chosen and justified using CAP/PACELC terms — `docs/design/consistency.md` (Inventory CP/PC-EC vs Catalog AP/EL, per-resource justification)
- [x] Inventory reservation implemented (conditional/atomic in PostgreSQL or state machine) — atomic conditional UPDATE + optimistic lock with bounded retry + `UNIQUE(order_id, route_id)`
- [x] Idempotency keys implemented across the full money path — `processed_events` per consumer (same-transaction), HTTP `Idempotency-Key` on `POST /orders`; idempotent replay verified live 2026-07-11 (200 + cached body)
- [x] Deduplication scheme documented in docs/design/idempotency.md
- [ ] Chaos experiment proves "never oversell" invariant holds under duplicate messages and Pod death — CE-2 designed (manual pre-test + k6 contention driver ready), **execution pending**

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
- [x] USE / infrastructure / Golden Signals dashboard — `dashboards/use-infrastructure.json`
- [x] Symptom-based alerts tied to SLOs (burn rate / user-visible symptoms, not CPU) — multi-window burn-rate rules (14× page / 6× ticket), CPU only as non-paging capacity ticket (PR #36)
- [x] Latency SLO and success-rate SLO for checkout defined with SLIs and error-budget statement — `docs/design/slo-definitions.md`, team-ratified 2026-07-11, incl. deploy-freeze policy
- [x] Distributed tracing across the money path — Tempo + OTLP (ADR 0022), W3C trace context propagated through Kafka (app PR #14)

## Chaos experiments

*All five designed with hypothesis, steady state, method, and pass/fail criteria; real
steady-state baselines captured 2026-07-11. **Execution pending** — results tables are empty.*

- [ ] Latency injection → Payments: circuit breaker opens, fallback engages, Catalog unaffected — `ce-1` ready to run (breaker live, Grafana breaker panel PR #67)
- [ ] Pod kill → Inventory mid-reservation: idempotency prevents oversell/double-charge — `ce-2` + manual pre-test + k6 contention driver ready
- [ ] Node/AZ disruption: PDBs and topology spread keep critical path available — `ce-3` ready
- [ ] Kafka partition: async pipeline recovers, nothing lost or duplicated — `ce-4` ready
- [x] CloudNativePG primary failover: observed impact on checkout, recovery within stated RTO — **run 2026-07-12, PASS: RTO 17.3 s ≤ 60 s, RPO 0/916** (`ce-5-cnpg-failover-run-1.md`; conclusion pending team ratification)
- [ ] Each experiment has: hypothesis, steady-state definition, observations, conclusion, changes made — hypothesis + steady state done for all five; observations/conclusions after the runs

## Agentic coding
- [x] Threat-model paragraph for the coding agent committed in docs/ — [`ai-threat-model.md`](ai-threat-model.md) (canonical; summarized in `CLAUDE.md`)
- [x] docs/agent-log.md contains at least three caught-and-corrected agent mistakes — **20 cases** as of 2026-07-12
- [ ] Team can explain, defend, and operate everything that was built — claimed and validated at the live presentation

## Deliverables
- [x] Application repository with history showing GitOps-driven delivery
- [x] Configuration repository with history showing GitOps-driven delivery
- [ ] docs/ containing all required documents — everything present except the postmortem, which is a template until the live-incident scenario runs
- [ ] Recorded demo (~5 min) committed as a link — to record during/after the chaos runs (must include an alert firing under injected failure)
- [ ] Live presentation scheduled — contact the teaching staff once chaos runs are done
