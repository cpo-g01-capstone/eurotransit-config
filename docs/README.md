# EuroTransit documentation map — start here

One page to orient in the documentation: **where is what, what was decided, how each
problem is addressed, and where the proof lives.** This file is a *map* — it links to the
authoritative documents and never restates their content (doc-drift is a recorded failure
class, app ADR-001). If a row here disagrees with the linked doc, the linked doc wins and
this map has a bug.

Repos: **config** = this repo (Helm chart, platform, docs) · **app** = `eurotransit-app`
(Kotlin services, CI, k6). App-repo paths are marked *(app)*.

---

## Pick your entry point

| You want to know… | Go to |
|---|---|
| How a capstone requirement is met, and where the code/manifests live | [`pillar-implementation-map.md`](pillar-implementation-map.md) |
| What was decided in delivery/platform, and the trade-off | [`../DELIVERY.md`](../DELIVERY.md) (31-row decision index → ADRs/runbooks) |
| The full record of any single decision | [`adr/`](adr/README.md) (28 ADRs, indexed) |
| Domain/design decisions the team owns (boundaries, consistency, SLOs…) | [`design/`](#design-decisions--team-owned-domain-choices) below |
| Are we done? What's left? | [`capstone-dod.md`](capstone-dod.md) (checklist + evidence) · [`deliverables-status-handout.md`](deliverables-status-handout.md) (spec-vs-state, 2026-07-15) |
| How to *operate* something (bootstrap, canary, TLS, DR…) | [`delivery/`](#runbooks--how-to-operate-it) runbooks below |
| What the AI agents got wrong, and their blast radius | [`agent-log.md`](agent-log.md) · [`ai-threat-model.md`](ai-threat-model.md) |
| What failed under chaos, and what we concluded | [`chaos-experiments/`](#chaos-experiments--proof-under-failure) below |

---

## Design decisions — team-owned domain choices

Per the agentic-coding policy these are authored and owned by the team, each with a named
owner. They are the "what we decided and why" layer for the domain (ADRs cover the
platform/delivery equivalents).

| Doc | Owner | Decides |
|---|---|---|
| [`design/service-boundaries.md`](design/service-boundaries.md) | @Lollegro | Decomposition + the sync/async rule ("synchronous only when a decision is needed now"); async cost analysis |
| [`design/consistency.md`](design/consistency.md) | @MauroC0l | Inventory is CP / PC-EC (reject under partition, never oversell); Catalog is the AP/EL counterpart |
| [`design/idempotency.md`](design/idempotency.md) | @MauroC0l | `{orderId}:{eventType}` composite key; dedup at consumer **and** DB level, same transaction |
| [`design/slo-definitions.md`](design/slo-definitions.md) | @marcodonatucci | Ratified 2026-07-11: checkout p95 < 500 ms, ≥ 99% success/30 d, burn-rate alerting, 429 excluded from the budget |
| [`design/data-flow.md`](design/data-flow.md) | @vojtech-n | Money-path topology: producers/consumers per topic, verified against code and live broker |

---

## Problem → decision → implementation → proof

The quick-orientation table. **Decision** = the immutable record; **How** = where the
mechanism is explained with code/manifest paths (usually a
[`pillar-implementation-map.md`](pillar-implementation-map.md) section); **Proof** = the
evidence that it works.

### Pillar A — distributed design & async execution

| Problem | Decision | How it's addressed | Proof |
|---|---|---|---|
| Sync/async service boundaries | [`design/service-boundaries.md`](design/service-boundaries.md); sync payment authorize: [ADR 0018](adr/0018-sync-payment-authorization-circuit-breaker.md) | Pillar map §A; [`design/data-flow.md`](design/data-flow.md) | Topology verified against code 2026-07-13 |
| Async order pipeline (Kafka stages) | Topics as Strimzi CRs, never auto-created ([ADR 0014](adr/0014-strimzi-v1-api-migration.md) for the API) | Pillar map §A; `kafka/kafka-topics.yaml` + *(app)* consumers | [CE-4](chaos-experiments/ce-4/) convergence, no loss/dup |
| Graceful shutdown, drain, no orphaned work | [ADR 0002](adr/0002-graceful-shutdown-and-probes.md) (drain-chain invariant); [ADR 0027](adr/0027-cpu-rightsizing-drain-headroom.md) (CPU headroom to actually drain) | Pillar map §A; *(app)* `GracefulShutdownManager` | *(app)* unit test; re-shown live in [CE-2](chaos-experiments/ce-2/)/[CE-3](chaos-experiments/ce-3/) |

### Pillar B — consistency under contention

| Problem | Decision | How it's addressed | Proof |
|---|---|---|---|
| Consistency model (CAP/PACELC) | [`design/consistency.md`](design/consistency.md) — CP/PC-EC Inventory | Pillar map §B; dedicated DBs: [ADR 0020](adr/0020-inventory-dedicated-database.md), [ADR 0024](adr/0024-notifications-dedicated-database.md) | [CE-2](chaos-experiments/ce-2/) DB-level invariant checks |
| Never oversell the last seat | Atomic conditional `UPDATE` + optimistic version + unique reservation constraint (design doc above) | Pillar map §B; *(app)* `RouteRepository.kt` | [CE-2](chaos-experiments/ce-2/) run 3 under k6 contention |
| No double-charge / double-processing | [`design/idempotency.md`](design/idempotency.md) | Pillar map §B; *(app)* `processed_events` in-transaction | [CE-2](chaos-experiments/ce-2/), [CE-4](chaos-experiments/ce-4/) |

### Pillar C — resilience engineering

| Problem | Decision | How it's addressed | Proof |
|---|---|---|---|
| Slow/failing Payments must not hang checkout | [ADR 0018](adr/0018-sync-payment-authorization-circuit-breaker.md) — breaker policy + queued-retry fallback | Pillar map §C; *(app)* `PaymentsClient.kt` | [CE-1](chaos-experiments/ce-1/) breaker opens, Catalog stays healthy |
| One slow dependency exhausting shared resources | Dedicated bounded connection pool (bulkhead) | Pillar map §C; *(app)* `PaymentsWebClientConfig.kt` | [CE-1](chaos-experiments/ce-1/) |
| Overload → controlled shedding, not collapse | 429 via RateLimiter; **excluded from SLO budget** ([`design/slo-definitions.md`](design/slo-definitions.md)) | Pillar map §C | k6 load runs *(app `tests/k6/`)* |
| Notifications down must not fail checkout | Terminal Kafka-only consumer + DLT + durable dedup (*(app)* ADRs 0001–0004) | Pillar map §C | Order CONFIRMED regardless; DLT drains safely |
| Pod death / node loss / upgrades | Probes: [ADR 0002](adr/0002-graceful-shutdown-and-probes.md) (liveness local-only — hard rule); PDB+spread+HPA: [ADR 0023](adr/0023-hpa-topology-spread-pdb-completion.md), [ADR 0025](adr/0025-hpa-owned-replica-count.md); HA + RTO/RPO: [ADR 0021](adr/0021-ha-replicas-and-rto-rpo.md) | Pillar map §C; chart `values.yaml` probe/lifecycle blocks, `templates/shared/` | [CE-3](chaos-experiments/ce-3/) node disruption; [CE-5](chaos-experiments/ce-5/) failover RTO 16.8 s / RPO 0 |

### Pillar D — delivery, observability, proof

| Problem | Decision | How it's addressed | Proof |
|---|---|---|---|
| Deploy without cluster creds in CI | [ADR 0007](adr/0007-gitops-writeback-github-app.md) (App token), [ADR 0010](adr/0010-acr-access-oidc-managed-identity.md) (OIDC→ACR), [ADR 0016](adr/0016-config-repo-branch-protection-ci-bypass.md) (bypass actor) | Pillar map §D; *(app)* `ci.yml`; `apps/eurotransit.yaml` | `eurotransit-gitops-writeback[bot]` commits in history |
| Chart packaging & rendering tools | [ADR 0008](adr/0008-single-helm-chart.md) (one chart), [ADR 0028](adr/0028-helm-over-kustomize.md) (Helm apps / Kustomize only for Argo CD bootstrap) | `deploy/charts/eurotransit/`; `bootstrap/install/` | `just helm-verify` / `helm-schema` gates ([ADR 0013](adr/0013-config-ci-validation.md)) |
| Promotion model & rollback | [ADR 0009](adr/0009-trunk-based-single-stack.md) — trunk-based, one stack; rollback = `git revert` | [`../DELIVERY.md`](../DELIVERY.md) rows 6–9 | GitOps history |
| Canary (Orders) & blue/green (Catalog) | [ADR 0026](adr/0026-progressive-delivery-canary-bluegreen.md) incl. promotion gate + DORA discussion | [`delivery/progressive-delivery-runbook.md`](delivery/progressive-delivery-runbook.md) | [`delivery/2026-07-11-progressive-delivery-demo-results.md`](delivery/2026-07-11-progressive-delivery-demo-results.md) |
| SLOs, alerts, dashboards | [`design/slo-definitions.md`](design/slo-definitions.md); symptom-based burn-rate alerts only | Pillar map §D; SLO, RED, lifecycle, trace-lookup and USE dashboards in chart `dashboards/`; `templates/*/prometheusrule.yaml` | Live during every chaos run |
| Tracing across the money path | [ADR 0022](adr/0022-distributed-tracing-tempo-otlp.md) — Tempo + OTLP, W3C context through Kafka headers, trace-only `order.id` correlation | Pillar map §D; `platform/monitoring/tempo.yaml`; `dashboards/order-trace.json` | Order ID lookup opens one trace across gateway→…→Notifications |

### Platform & operations (not pillar-mapped)

| Problem | Decision | How / runbook |
|---|---|---|
| Cluster sizing & cost under student quota | [ADR 0001](adr/0001-aks-cluster-sizing-and-budget.md), [ADR 0005](adr/0005-node-sizing-under-vcpu-quota.md), [ADR 0006](adr/0006-drop-k3d-azure-only.md) | [`../DELIVERY.md`](../DELIVERY.md) rows 1–3 |
| First bring-up & steady state | App-of-apps, wave order + health gates; operator pins: [ADR 0004](adr/0004-operator-version-pinning.md); sync options: [ADR 0003](adr/0003-argocd-sync-options-for-operator-crds.md) | [`delivery/bootstrap-flow.md`](delivery/bootstrap-flow.md) |
| Argo CD blast radius & access | [ADR 0011](adr/0011-scoped-appprojects.md) (two AppProjects); GitHub SSO | [`delivery/argocd-sso.md`](delivery/argocd-sso.md) · [`delivery/argocd-ui-access.md`](delivery/argocd-ui-access.md) · webhook: [ADR 0015](adr/0015-argocd-github-webhook.md) |
| Public TLS | cert-manager + Let's Encrypt, staging→prod; Traefik `IngressRoute` only ([ADR 0012](adr/0012-traefik-ingressroute-over-ingress.md)) | [`delivery/tls-issuance-runbook.md`](delivery/tls-issuance-runbook.md) |
| Secrets in Git | SealedSecrets only, strict scope; key loss = re-seal | [`delivery/sealed-secrets-key-dr.md`](delivery/sealed-secrets-key-dr.md) |
| Namespace isolation | default-deny NetworkPolicy | [`delivery/network-policy-checklist.md`](delivery/network-policy-checklist.md) |
| Config-repo quality gates | [ADR 0013](adr/0013-config-ci-validation.md) — helm-verify/schema, kube-linter, gitleaks | `.github/workflows/validate.yml` |
| Chaos operator install & execution model | [ADR 0017](adr/0017-chaos-mesh-installation.md) | `platform/chaos-mesh/` |
| Static hardening findings | — | [`hardening-handout.md`](hardening-handout.md) (2026-07-14 scan) |

### Chaos experiments — proof under failure

All follow steady state → hypothesis → single injection → observation → conclusion.
Hypotheses and conclusions are team-owned.

| # | Experiment | Directory |
|---|---|---|
| CE-1 | Latency → Payments (breaker + fallback, Catalog unaffected) | [`chaos-experiments/ce-1/`](chaos-experiments/ce-1/) |
| CE-2 | Pod kill → Inventory mid-reservation (never-oversell) | [`chaos-experiments/ce-2/`](chaos-experiments/ce-2/) |
| CE-3 | Node/AZ disruption (PDBs + topology spread) | [`chaos-experiments/ce-3/`](chaos-experiments/ce-3/) |
| CE-4 | Kafka partition (pipeline convergence, no loss/dup) | [`chaos-experiments/ce-4/`](chaos-experiments/ce-4/) |
| CE-5 | CNPG primary failover (RTO 16.8 s, RPO 0 — run 3 PASS) | [`chaos-experiments/ce-5/`](chaos-experiments/ce-5/) |
| CE-6 | Pod kill → Payments | [`chaos-experiments/ce-6/`](chaos-experiments/ce-6/) |

### Governance, agentic policy & presentation

| Doc | What it is |
|---|---|
| [`agent-log.md`](agent-log.md) | Graded record of agent mistakes caught and corrected (≥3 required) — custodian @marcodonatucci |
| [`ai-threat-model.md`](ai-threat-model.md) | Canonical agent blast-radius analysis (CLAUDE.md summary must stay consistent with it) |
| [`adr/README.md`](adr/README.md) | ADR conventions + index; Proposed → Accepted → Superseded; ADRs immutable once Accepted |
| [ADR 0019](adr/0019-single-approval-review-policy.md) | Review policy: single approval, CODEOWNERS flattened |
| [`ownership-map.md`](ownership-map.md) | Who owns which code per domain, across both repos (mirrors the CODEOWNERS path blocks) |
| [`agents/vojtech.md`](agents/vojtech.md) · [`agents/mauro.md`](agents/mauro.md) | Per-owner scope, invariants, and how to contribute to their area |
| [`demo-recording-handout.md`](demo-recording-handout.md) | Step-by-step runbook for the 5-min demo recording |
| [`deliverables-status-handout.md`](deliverables-status-handout.md) | Spec-vs-state snapshot (2026-07-15) |
| [`postmortem.md`](postmortem.md) | Blameless postmortem — to be completed after the live incident scenario |

---

## Keeping this map honest

- Add a row (or extend one) **in the same PR** that adds a new doc, ADR, or experiment.
- Never copy content in — link to it. The linked doc is authoritative.
- Known paired-docs rule: `design/data-flow.md` ↔ `.agent/context/kafka-topics.md` must be
  updated in the same PR (app ADR-001).
