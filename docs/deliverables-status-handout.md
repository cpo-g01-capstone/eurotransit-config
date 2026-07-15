# EuroTransit — Deliverables Status Handout

State of the project measured against the capstone spec (`CapstoneProject.local.md`),
as of **2026-07-15**. Evidence links point at this repo unless marked *(app repo)*.

## Summary

| Spec deliverable | Status |
|---|---|
| 1. Two repos with GitOps-driven history | ✅ Done |
| 2. `docs/` — DoD, design/consistency, SLOs, chaos reports, postmortem, threat model, agent-log | 🟡 One item outstanding (postmortem — by design, post-presentation) |
| 3. Recorded ~5-min demo, link committed | ❌ Not recorded (runbook ready) |
| Live presentation scheduled | ❌ Not scheduled — **unblocked now** |

All four pillars and all five chaos experiments are **complete with passing
evidence**. The remaining work is packaging: record the demo, refresh the stale
DoD checklist, schedule the presentation.

---

## Deliverable 1 — The two repositories

**Spec:** "The two repositories (application plus configuration), with history
that shows GitOps-driven delivery."

✅ **Done.** The config-repo history itself is the proof: `ci(eurotransit-app):
bump image tags to <sha>` commits authored by `eurotransit-gitops-writeback[bot]`
(short-lived GitHub App token, ADR 0007; ACR via OIDC, ADR 0010; branch
protection + deliberate CI bypass, ADR 0016). CI holds no cluster credentials;
Argo CD reconciles (`selfHeal` + `prune` true).

---

## Deliverable 2 — `docs/` contents, item by item

| Required document | Status | Evidence |
|---|---|---|
| DoD | ✅ exists / ⚠️ **stale** | `docs/capstone-dod.md` — see "Corrections needed" below |
| Design / consistency justification | ✅ | `docs/design/service-boundaries.md` (sync/async boundaries + async cost analysis), `docs/design/consistency.md` (Inventory CP/PC-EC vs Catalog AP/EL) |
| SLO definitions | ✅ | `docs/design/slo-definitions.md` — latency + success-rate SLOs, error budget, deploy-freeze policy, team-ratified 2026-07-11 |
| Chaos-experiment reports | ✅ | all five under `docs/chaos-experiments/ce-{1..5}/` — see table below |
| Postmortem | 🟡 template | `docs/postmortem.md` — deliberately empty: the spec ties it to the live-incident scenario at the presentation ("run a live incident during presentation, recover, and produce a blameless postmortem"). Defensible, but be ready to say so out loud. |
| Agent threat-model paragraph | ✅ | `docs/ai-threat-model.md` (canonical), summarized in `CLAUDE.md` |
| `agent-log.md` (≥ 3 cases, graded) | ✅ **22 cases** | `docs/agent-log.md` — latest: Case 22 (Kafka SASL secret-key contract, issue #97 / PR #98) |

### Chaos experiments — spec requires all five, run as hypotheses

| # | Spec experiment | Result | Report |
|---|---|---|---|
| CE-1 | Latency → Payments: breaker opens, fallback engages, Catalog healthy | ✅ PASS (run 5, incl. guard against Case-24 recurrence; scope revised twice — documented) | `ce-1/ce-1-latency-payments-run-5.md` |
| CE-2 | Pod kill → Inventory mid-reservation: no oversell / double-charge | ✅ PASS (run 3, 2537 = 2537, mid-reservation kill) | `ce-2/ce-2-pod-kill-inventory-run-3.md` |
| CE-3 | Node/AZ disruption: PDBs + topology spread hold the critical path | ✅ PASS (re-run after capacity fix #89/#90, 0.008 % errors; DB verification battery in #92) | `ce-3/ce-3-node-disruption-run-2.md` |
| CE-4 | Kafka partition: pipeline recovers, nothing lost or duplicated | ✅ PASS (no loss, no duplicates) | `ce-4/ce-4-kafka-partition-run-1.md` |
| CE-5 | CNPG primary failover: impact on checkout, recovery within RTO | ✅ PASS (run 3 reviewer reproduction: RTO 16.8 s ≤ 60 s, RPO 0, 1021 = 1021) | `ce-5/ce-5-cnpg-failover-run-3.md` |

Each report carries hypothesis → steady state → observation → conclusion, and
several produced real fixes (CE-1's injection scoping, CE-3's CPU rightsizing
ADR 0027, CE-5's graceful-vs-crash method correction, agent-log Case 21) —
exactly the "what you changed if it didn't hold" the spec asks for.

---

## Deliverable 3 — Recorded ~5-min demo ❌

**Spec:** "showing: the running system, the dashboards answering operational
questions, a canary and a blue/green deployment, and at least one alert firing
under an injected failure. Link committed in the repo."

Not recorded yet. Everything it must show has already been demonstrated live:

- Canary: PRs #58/#59 — 10.06 % split, gate held, promoted (`docs/delivery/2026-07-11-progressive-delivery-demo-results.md`)
- Blue/green: PRs #61/#62/#63 — atomic IngressRoute cutover on Catalog
- Alert under failure: CE-1 exercised `PaymentsHighP95Latency` under injected latency

**The step-by-step recording runbook is ready: `docs/demo-recording-handout.md`**
(four segments, pre-approved PRs, CE-1 timed to catch pending→firing on camera).
After recording: commit the link (README or DoD) — that closes DoD item "Recorded demo".

---

## Pillar-by-pillar cross-check (spec §"What you must demonstrate")

| Pillar | Spec requirements | Status |
|---|---|---|
| **A — Distributed design & async** | Decomposition + boundaries justified; coroutine/Flow pipeline; structured concurrency; SIGTERM cancellation demonstrated; readiness refuses while draining; written async cost analysis | ✅ all — `service-boundaries.md`, app `GracefulShutdownManager` (+test), drain chain in `values.yaml` (ADR 0002); re-demonstrated live by CE-2/CE-3 |
| **B — Consistency under contention** | CAP/PACELC choice with explicit partition sacrifice; implementation; money-path idempotency + documented scheme; invariant proven under chaos | ✅ all — `consistency.md`, atomic conditional UPDATE + `UNIQUE(order_id, route_id)`, `processed_events` same-transaction dedup + HTTP `Idempotency-Key` (`docs/design/idempotency.md`); **CE-2 PASS closes the last open item** |
| **C — Resilience engineering** | Circuit breakers w/ policy + fallback; bulkheads; timeouts + bounded retries w/ jitter; 429 load shedding; Notifications degrade gracefully; deliberate probes; PDBs | ✅ all — ADR 0018 breaker (fallback = queued Kafka redelivery), dedicated Payments pool, RateLimiter `timeoutDuration: 0`, DLT + durable dedup, shared probe block (liveness local-only), five PDBs + topology spread (ADR 0023) |
| **D — Delivery, observability, proof** | GitOps w/o CI creds; canary AND blue/green demonstrated; DORA discussion; RED + USE dashboards; symptom/burn-rate alerts; latency + success SLOs w/ error budget; distributed tracing | ✅ all — see Deliverable 1; both strategies demoed 2026-07-11; ADR 0026 §DORA; two GitOps-delivered dashboards; multi-window burn-rate rules (14×/6×); Tempo + OTLP w/ trace context through Kafka (ADR 0022) |
| **Agentic coding policy** | Artifacts-not-judgments split; blast-radius threat model; ≥ 3 logged agent mistakes | ✅ all — policy in `CLAUDE.md`, `ai-threat-model.md`, 22 agent-log cases |

Beyond spec (worth mentioning at the presentation): security hardening pass
(`docs/hardening-handout.md` — securityContext/PSA-ready, non-root images,
Kafka SCRAM auth), NetworkPolicies, scoped Argo CD AppProjects (ADR 0011),
27 ADRs documenting every judgment call.

---

## Corrections needed in `docs/capstone-dod.md` (stale since ~2026-07-12)

The checklist predates the chaos-run completions. To fix:

1. **Tick items 49–53** (CE-1..CE-4 — all now executed PASS; CE-5 already ticked)
2. **Tick item 22** (Pillar B chaos proof — CE-2 run 3 PASS)
3. **Tick item 54** (hypothesis→conclusion complete for all five)
4. Update the agent-log count in item 58 (“20 cases” → 22)
5. Resolve any “conclusion pending team ratification” notes (CE-5) — ratify or drop

---

## The critical path to "done" (in order)

| # | Action | Owner | Blocked by |
|---|---|---|---|
| 1 | Refresh `capstone-dod.md` (corrections above) | team | nothing |
| 2 | Record the 5-min demo per `demo-recording-handout.md` | @vojtech-n + one approver | nothing |
| 3 | Commit the demo link | — | 2 |
| 4 | **Contact teaching staff to schedule the live presentation** (spec: "once the system is ready") | team | 2–3 |
| 5 | Postmortem — completed after the live-incident scenario at the presentation | team | 4 |

Everything the team controls is finishable this week; only the presentation
date and the postmortem depend on the staff.
