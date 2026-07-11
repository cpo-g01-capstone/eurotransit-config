# ADR 0017 — Chaos Mesh installation and experiment execution model

- **Status:** Proposed
- **Date:** 2026-07-11
- **Author:** @giova95 (chaos & verification)
- **Related:** capstone spec "Chaos engineering"; ADR 0004 (version pinning);
  ADR 0011 (AppProjects); `docs/chaos-experiments/`

## Context

The capstone requires five controlled chaos experiments run with Chaos Mesh (or
equivalent), each following the scientific method: steady state → hypothesis → inject one
failure → observe → conclude. Nothing chaos-related was installed so far. Two design
questions had to be answered:

1. **How is the operator installed?** — consistently with every other platform component
   (Argo CD Application under `platform/`, pinned version, wave 0).
2. **How are the experiments applied?** — this is the interesting one. Our GitOps rule is
   "Git is the source of truth, Argo reconciles everything, `selfHeal: true`". Applied
   naively to chaos experiments this is a trap: **a PodChaos object reconciled by Argo CD
   with selfHeal would be re-applied after every cleanup — the fault injection would never
   end.** Chaos is *deliberately transient*; desired state must NOT contain a live fault.

## Decision

1. **Operator via Argo CD** — `platform/chaos-mesh/chaos-mesh.yaml`, chart
   `chaos-mesh/chaos-mesh` pinned at **2.7.2** (bump deliberately; `just platform-verify`
   checks the pin resolves and renders). Namespace `chaos-testing`, `ServerSideApply=true`
   (large CRDs), AKS containerd socket configured explicitly.

2. **Experiments are NOT Argo-managed.** Experiment CRs live in
   `docs/chaos-experiments/*.yaml` — intentionally *outside* any Argo `source.path` — and
   are applied manually during an experiment window:
   `just chaos <name>` / `just chaos-clean <name>`. Each run is recorded in the paired
   report (`docs/chaos-experiments/<name>.md`). Git still tracks *what* we inject
   (versioned manifests, reviewed in PR) — it just does not *continuously enforce* it.

3. **Blast-radius guardrail** — `controllerManager.enableFilterNamespace=true`: Chaos Mesh
   can only target namespaces annotated `chaos-mesh.org/inject=enabled`. We annotate
   **only `eurotransit`** (`just chaos-enable`). A wrong selector can therefore never
   touch platform pods (Argo CD, Prometheus, Strimzi, CNPG, Traefik). This mirrors the
   course's security framing: the chaos controller is a powerful non-human actor inside
   the cluster — least privilege applies to it like to CI and coding agents.

4. **Dashboard trade-off** — `dashboard.securityMode=false` (no in-dashboard token) is
   accepted ONLY because the dashboard stays ClusterIP and is reached exclusively via
   `just chaos-dashboard` (port-forward, needs kubeconfig). It is never exposed through
   Traefik. Anyone with port-forward rights already holds cluster credentials that exceed
   the dashboard's power.

## Consequences

- CE-2 (Pod kill on Inventory) is runnable now: manifest + report skeleton committed.
- CE-1 (latency → Payments) stays **blocked on the team's authorization-mode decision** (since taken: sync call + circuit
  breaker vs Kafka-only) — the injection target depends on it.
- CE-4 (Kafka partition) and CE-5 (CNPG failover) stay **blocked on the HA-replica decision** (since taken, ADR 0021; with 1
  broker / 1 DB instance there is nothing to fail over to).
- CE-3 (node disruption) needs no operator support beyond PDBs: `kubectl drain` on an AKS
  node is the injection; a manifest-less runbook will be added with its report.
- The `platform` AppProject must list `https://charts.chaos-mesh.org` in its
  `sourceRepos` — Argo validates an Application's `source.repoURL` against its
  project's `sourceRepos`, and the platform project only allowed the config repo
  (caught at sync as `InvalidSpecError`; see agent-log case 14). Experiment CRs are
  applied with user credentials, not by Argo, so the `eurotransit` AppProject is
  untouched.

## Alternatives considered

- **Argo-managed experiments with `syncPolicy: none`** — keeps everything under one app
  but makes accidental auto-sync one click away, and clutters app health with
  intentionally-failing resources. Rejected.
- **Litmus Chaos** — also CNCF, workflow-oriented; Chaos Mesh chosen because the course
  material names it, the CRD model is simpler, and the dashboard helps the live demo.
- **Cluster-scoped, unfiltered targeting** — default, rejected: one typo in a selector
  could kill Argo CD or Prometheus mid-demo.
