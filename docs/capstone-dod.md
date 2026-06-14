# Capstone Definition of Done

All five team members must approve changes to this file.

## Pillar A — Distributed design and async execution
- [ ] Service decomposition documented with explicit sync/async boundaries and justification
- [ ] Order pipeline implemented with Kotlin coroutines / Flows
- [ ] Structured concurrency: one CoroutineScope per failure domain
- [ ] Cooperative cancellation on SIGTERM demonstrated (no orphaned tasks, no double-processing)
- [ ] Readiness flips to refusing traffic while in-flight work drains
- [ ] Written analysis: where async reduces cost in EuroTransit and where it would not help

## Pillar B — Consistency under contention
- [ ] Consistency model chosen and justified using CAP/PACELC terms
- [ ] Inventory reservation implemented (conditional/atomic in PostgreSQL or state machine)
- [ ] Idempotency keys implemented across the full money path
- [ ] Deduplication scheme documented in docs/design/idempotency.md
- [ ] Chaos experiment proves "never oversell" invariant holds under duplicate messages and Pod death

## Pillar C — Resilience engineering
- [ ] Circuit breakers on Orders → Payments with open/half-open policy and defined fallback
- [ ] Bulkheads: isolated resource pools per flow
- [ ] Bounded retries with backoff and jitter on every remote call
- [ ] Backpressure / load shedding (HTTP 429) under overload
- [ ] Notifications failure does not fail checkout
- [ ] Meaningful startup / readiness / liveness probes (liveness does NOT check downstream)
- [ ] PodDisruptionBudgets on all critical-path services

## Pillar D — Delivery, observability, proof
- [ ] GitOps delivery: CI updates config-repo; Argo CD reconciles; CI holds no cluster credentials
- [ ] Canary demonstrated via TraefikService: small fraction → watch SLIs → promote or abort
- [ ] Blue/green demonstrated: stand up new version → switch traffic → fast rollback available
- [ ] DORA strategy discussion: where rolling and all-at-once would fit, why not used on critical path
- [ ] Per-service RED dashboards in Grafana
- [ ] USE / infrastructure / Golden Signals dashboard
- [ ] Symptom-based alerts tied to SLOs (burn rate / user-visible symptoms, not CPU)
- [ ] Latency SLO and success-rate SLO for checkout defined with SLIs and error-budget statement
- [ ] Distributed tracing across the money path

## Chaos experiments
- [ ] Latency injection → Payments: circuit breaker opens, fallback engages, Catalog unaffected
- [ ] Pod kill → Inventory mid-reservation: idempotency prevents oversell/double-charge
- [ ] Node/AZ disruption: PDBs and topology spread keep critical path available
- [ ] Kafka partition: async pipeline recovers, nothing lost or duplicated
- [ ] CloudNativePG primary failover: observed impact on checkout, recovery within stated RTO
- [ ] Each experiment has: hypothesis, steady-state definition, observations, conclusion, changes made

## Agentic coding
- [ ] Threat-model paragraph for the coding agent committed in docs/
- [ ] docs/agent-log.md contains at least three caught-and-corrected agent mistakes
- [ ] Team can explain, defend, and operate everything that was built

## Deliverables
- [ ] Application repository with history showing GitOps-driven delivery
- [ ] Configuration repository with history showing GitOps-driven delivery
- [ ] docs/ containing all required documents
- [ ] Recorded demo (~5 min) committed as a link
- [ ] Live presentation scheduled
