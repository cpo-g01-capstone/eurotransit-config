# ADR 0003 — Argo CD sync options for operator-CRD dependencies

- **Status:** Proposed
- **Date:** 2026-07-01
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** platform, gitops
- **Supersedes / Superseded by:** —

---

## Context

The platform bootstraps as an Argo CD app-of-apps: `root-app` → `platform` (operators)
+ `workloads` (Kafka, Postgres, the app chart). Two recurring failure modes surfaced
while validating the bootstrap on a live cluster (see `docs/agent-log.md` cases 8–10):

1. **Operators install large CRDs.** cert-manager, CloudNativePG, Strimzi, and
   kube-prometheus-stack ship CRDs whose schemas exceed the client-side apply
   annotation limit (262144 bytes). Client-side apply fails with
   `metadata.annotations: Too long`, so the CRD — and everything depending on it —
   never installs.

2. **Workloads reference CRDs owned by a different app.** The app chart ships
   `ServiceMonitor`/`PrometheusRule` (kube-prometheus-stack), `IngressRoute`/
   `TraefikService` (Traefik), a `Certificate` (cert-manager); the `kafka` app ships
   `Kafka`/`KafkaTopic` (Strimzi); the `data` app ships a CNPG `Cluster`. A
   `sync-wave` only orders resources **within one Application's sync** — it does not
   reliably wait for a *different* app to finish installing its CRDs. So a workload
   can sync before its CRD exists and hard-fail with `SyncFailed / Missing`.

Both are timing/ordering problems inherent to splitting operators and their consumers
across separate Argo Applications.

## Decision

1. **`ServerSideApply=true`** on every operator Application that installs large CRDs:
   `cert-manager`, `cloudnative-pg`, `strimzi`, `kube-prometheus-stack`. Server-side
   apply is not subject to the client-side annotation size limit. (`sealed-secrets`
   and `traefik` have small CRDs and are left on client-side apply until proven
   otherwise.)

2. **`SkipDryRunOnMissingResource=true`** on workload Applications whose CRs depend on
   CRDs installed by a different app: `eurotransit`, `eurotransit-kafka`,
   `eurotransit-data`. The sync retries (eventual consistency) instead of hard-failing
   until the CRD is registered.

3. **Compensating control:** a `kubeconform` schema-validation step (`just helm-schema`,
   wired into CI) to recover the validation safety that `SkipDryRunOnMissingResource`
   gives up — a typo'd `kind`/`apiVersion` should fail a PR, not be silently treated as
   a missing CRD that retries forever.

### Cross-Application ordering is a hint, not a gate

The app-of-apps uses `sync-wave: "0"` on `platform` and `"1"` on `workloads`, and finer
waves inside them. **Sync-waves reliably order resources *within a single Application's*
sync; between *separate* Applications they only order when Argo creates the child
Application resource — they do not block wave 1 from syncing until wave 0's children are
Healthy.** So the wave annotations are a *hint* that usually helps, but they are **not** the
mechanism that prevents a workload CR from applying before its CRD exists.

The real guarantee is decision **2** — `SkipDryRunOnMissingResource` + Argo's idempotent
retry: a CR whose CRD isn't registered yet is retried, not hard-failed, until the CRD
appears. This is coherent and sufficient for our bootstrap. If stronger gating is ever
wanted, the right lever is a **health-based retry/backoff** on the workload Applications
(let Argo's health assessment + a `retry` backoff converge), **not** strict CRD-first
ordering (see Alternatives). Low priority — the retry already converges in practice.

## Alternatives considered

- **Strict CRD-first ordering** (a dedicated Application installing all operator CRDs at
  the earliest sync-wave, so every downstream app can assume they exist). **Evaluated and
  rejected** (2026-07-09):
  - **Ongoing maintenance / drift.** cert-manager, CloudNativePG, Strimzi and
    kube-prometheus-stack ship their CRDs *inside* their charts. CRD-first means extracting
    those into a separately-versioned manifest set that must be re-synced on every operator
    bump — new duplication and a new drift failure mode (the CRD copy silently lagging the
    operator version).
  - **Doesn't fully solve ordering.** Some operators need the *controller* running, not just
    the CRD registered — e.g. the CNPG `Cluster` admission webhook (a retired setup-era agent-log entry; full text in Git history). CRD-first
    would still race the webhook, so it adds complexity without closing the gap.
  - **Validation is already recovered** by the `kubeconform` control (decision 3), so the main
    benefit of CRD-first (keeping downstream dry-run) is largely redundant here.
  - **When it would be worth it:** many teams/apps sharing CRDs under strict change management —
    not a single-cluster, five-person capstone. Revisit only if the retry approach proves noisy.
- **`Replace=true`** to sidestep the annotation-size limit. Rejected: it is destructive
  (deletes and recreates resources) and risky for CRDs holding live CRs.
- **Rely on sync-waves / retries alone.** Rejected: cases 9–10 showed wave gating does
  not reliably wait on another app's CRD installation; without the options above the
  bootstrap wedges on a fresh cluster.

## Consequences

- **Easier:** a fresh cluster bootstraps deterministically regardless of operator/CR
  install timing; no manual re-sync ordering.
- **Harder / risk:** `SkipDryRunOnMissingResource` weakens validation — a genuinely
  wrong `kind`/`apiVersion` is treated as "missing CRD, will retry" rather than failing
  loudly. Blast radius is limited (built-in kinds still get full dry-run), and the
  `kubeconform` control is the mitigation. `ServerSideApply` changes field-ownership
  semantics; it is the recommended mode for operator charts, but field-manager conflicts
  can appear if the same fields are edited out of band.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance during the EM-31 platform-bootstrap work. Before ratifying:

- [ ] Confirm the four operator apps reach Synced+Healthy on a fresh cluster with
      `ServerSideApply=true` (CRDs install).
- [ ] Confirm the three workload apps converge (their CRs apply once CRDs exist).
- [ ] Confirm `just helm-schema` (kubeconform) runs in CI and fails on a deliberately
      broken manifest.
- [x] Strict CRD-first ordering evaluated and rejected (2026-07-09); eventual-consistency
      via `SkipDryRunOnMissingResource` + retry is the standing approach (see Alternatives).

## References

- `docs/agent-log.md` cases 8 (kubeVersion), 9 (CNPG webhook readiness), 10 (cross-app CRD sync-wave).
- Argo CD sync options: `ServerSideApply`, `SkipDryRunOnMissingResource`.
- CLAUDE.md — GitOps delivery rules; agentic-coding policy.
