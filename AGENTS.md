# AGENTS.md — EuroTransit Configuration Repository

Canonical instructions for **any** coding agent (Cursor, Claude Code, Codex, etc.)
working in this repository. Read this file **first**, before generating any manifest,
chart, dashboard, or doc. It tells you how to work, what to document, and what you must never do.

> This repo (`eurotransit-config`) owns the **desired state**: Helm charts, platform
> bootstrap, Argo CD config, SealedSecrets, observability/chaos manifests, and project docs.
> Application **source code, tests, and CI** live in the **application repository**
> `eurotransit-app`.

---

## 1. Read context in this order

Before producing any artifact, load the relevant context. The project is graded on
operational correctness and on the quality of its documentation — never generate from
assumptions.

1. **`CLAUDE.md`** (this repo) — the authoritative technical reference: architecture
   constraints, repo model, probe rules, secrets policy, GitOps rules, progressive delivery,
   observability, chaos, naming, "common mistakes to reject". Read it.
2. **`.agent/agents/<role>-owner.md`** — per-role ownership, fixed decisions, invariants,
   review checklists, and canonical YAML snippets. The five roles:
   `delivery-owner`, `domain-async-owner`, `consistency-owner`, `resilience-owner`,
   `observability-owner`.
3. **`.agent/context/`** — `money-path.md`, `kafka-topics.md`, `db-schema.md`
   (the shared facts the whole money path depends on).
4. **`.agent/decisions/ADR-001-template.md`** — the ADR format to use for new decisions.
5. **`docs/`** — `capstone-dod.md` (the single grading reference), `design/`, `agent-log.md`,
   `postmortem.md`.

---

## 2. What this repo owns

- Helm chart: `deploy/charts/eurotransit/` (one source of truth for image tags, replicas,
  resources, probes, PDBs, HPA, ServiceMonitor, PrometheusRule, TraefikService, SealedSecrets)
- Platform bootstrap: `platform/` (Traefik, cert-manager, CloudNativePG, Strimzi/Kafka,
  Sealed Secrets, Argo CD, kube-prometheus-stack, Chaos Mesh)
- Argo CD `Application` definitions
- Project documentation under `docs/` (DoD, design docs, ADRs, agent-log, chaos reports,
  postmortem)

**Not owned here** (→ application repository): service source code, Dockerfiles, the
build/test/push CI workflow, k6 scripts, the justfile.

CI in the app repo produces immutable images → bumps tags in this repo's `values.yaml`
→ **Argo CD reconciles**. This repo never gets pushed to the cluster by CI.

---

## 3. How to work (mandatory workflow)

Follow the project workflow from `KICKOFF.md §5`:

1. Pick up an issue from the project board; mark it **In Progress**.
2. Branch off `main`: `feature/<id>-short-desc`, `fix/<id>-...`, `chore/<id>-...`.
   Never push directly to protected `main`.
3. Validate locally before opening a PR:
   - `helm lint deploy/charts/eurotransit/`
   - `helm template eurotransit deploy/charts/eurotransit/ --namespace eurotransit | kubectl apply --dry-run=client -f -`
4. Commit atomically. English message format: `type(scope): description`
   (e.g. `feat(observability): add checkout burn-rate alert`).
5. Open a PR linked to the issue, describing the change and rationale.
6. PR requires **≥1 human review**, preferably the **role owner**
   (`.agent/agents/<role>-owner.md` review checklist). CI green before merge.
7. After merge, move the task to **Verify**, then **Done**.

---

## 4. Documentation duties (this is graded)

Documentation lives here and is a first-class deliverable. Update or create the relevant
doc **in the same PR** as the change:

| If you change / decide… | Update / create… |
|---|---|
| A meaningful architectural or platform decision | An ADR in `docs/adr/` (template: `.agent/decisions/ADR-001-template.md`) |
| Service boundaries, sync/async split | `docs/design/service-boundaries.md` |
| Inventory consistency model | `docs/design/consistency.md` — both faces of CAP/PACELC, with justification |
| Idempotency / deduplication scheme | `docs/design/idempotency.md` |
| SLO targets, SLIs, error budget | `docs/design/slo-definitions.md` |
| Any chaos experiment | `docs/chaos/CE-<n>.md` (hypothesis → steady state → observation → conclusion) |
| The grading checklist | `docs/capstone-dod.md` (the single source of truth for evaluation) |
| An incident / failure analysis | `docs/postmortem.md` (blameless: systems & process, not people) |

**Agent-log (mandatory deliverable):** every time a human catches an AI artifact that was
wrong, unsafe, or subtly wrong (over-permissive ServiceAccount, liveness probe checking a
downstream, cause-based alert, `prune: false`, plaintext secret, etc.), record it in
`docs/agent-log.md` using the template in `KICKOFF.md §8`. The project requires
**≥3 documented cases**.

**Decisions the AI must not make alone** (`KICKOFF.md §8`): service decomposition,
consistency model, SLO definitions, failure-mode mapping, chaos hypotheses, postmortem
content. Draft scaffolding and propose options, but the team owns the decision and its
written justification.

---

## 5. Hard technical rules (reject violations)

Non-negotiable. Full detail + rationale in `CLAUDE.md` ("Common mistakes to reject").

- **Liveness** probes check only local process health — never DB/Kafka/downstream.
  **Readiness** flips to refusing traffic while draining.
- Every container sets `resources:` requests and limits; image tags come from `values.yaml`
  (never hardcoded in templates); prefer immutable tags + `IfNotPresent`.
- **Secrets only as `SealedSecret`** (strict scope, controller `sealed-secrets` in namespace
  `sealed-secrets`). Never commit a plaintext `kind: Secret`.
- **CI never holds cluster credentials**; no `kubectl apply` / `helm upgrade` in CI.
  Delivery is pull-based via Argo CD.
- Argo CD `Application`: keep `automated.selfHeal: true` and `prune: true`.
  Rollback = `git revert` on this repo, never `kubectl rollout undo`.
- Kafka topics are declared as `KafkaTopic` CRs (never auto-created in code). Fixed topics:
  `order-placed`, `inventory-reserved`, `payment-authorized`, `order-confirmed`,
  `notification-requested`.
- Every critical-path service has a **PodDisruptionBudget**; alerts are **symptom-based**
  (burn rate, error rate, latency) — never CPU/memory thresholds.

Naming, namespaces, and canonical YAML shapes (Argo CD Application, TraefikService canary,
KafkaTopic, values.yaml) are fixed — copy them from `.agent/agents/delivery-owner.md` and
`CLAUDE.md`. Do not invent variants.

---

## 6. Forbidden actions for AI in this repo

Aligned with `.claude/settings.json` (the enforced permission boundary):

- Do **not** write to `.github/CODEOWNERS`, `.claude/settings.json`, or
  `.env*` / `*.pem` / `*.key`.
- Do **not** run `git push`, `git commit`, mutating `kubectl` (`apply`/`delete`/`edit`/
  `patch`), `helm upgrade`/`install`/`uninstall`/`rollback`, `az`, `kubeseal`, `argocd`,
  `rm -rf`, or piped-to-shell installers. Read-only and `--dry-run=client` are fine.
- Do **not** add cluster credentials to any workflow.
- Do **not** merge AI-generated manifests without human review — *"if you cannot explain
  why it works, do not merge it"* (`KICKOFF.md §8`).

### Blast radius

This agent may open PRs that change desired state Argo CD reconciles into the cluster.
Mitigations (also recorded in `docs/ai-threat-model.md`): the agent holds no cluster
credentials; all PRs need ≥1 human approval; `helm lint` + `helm template | dry-run`
run in CI on every PR. Worst case — a bad manifest merges and degrades a service — is
recovered by `git revert` + Argo CD self-heal, and documented in `docs/agent-log.md`.

---

*Entry point for agents. Deep technical reference: `CLAUDE.md`. Per-role context:
`.agent/agents/`. Project rationale and roadmap: root `KICKOFF.md`. Keep this file in sync
with `.claude/settings.json` and `CLAUDE.md`.*
