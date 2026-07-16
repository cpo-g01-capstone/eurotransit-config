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
   `Kafka`/`KafkaTopic` (Strimzi); the `data` app ships a CNPG `Cluster`. Argo CD
   removed the built-in health assessment for `argoproj.io/Application`, so an
   app-of-apps sync-wave normally orders creation of child Application objects but
   does not wait for those child Applications to become Healthy. A workload can
   therefore sync before a different Application has finished installing its CRDs
   and controllers.

Both are timing/ordering problems inherent to splitting operators and their consumers
across separate Argo Applications.

## Decision

1. **`ServerSideApply=true`** on every operator Application that installs large CRDs:
   `cert-manager`, `cloudnative-pg`, `strimzi`, `kube-prometheus-stack`. Server-side
   apply is not subject to the client-side annotation size limit. (`sealed-secrets`
   and `traefik` have small CRDs and are left on client-side apply until proven
   otherwise.)

2. **Restore health assessment for child `Application` resources** in
   `bootstrap/install/patch-argocd-cm.yaml`, using Argo CD's documented
   `resource.customizations.health.argoproj.io_Application` Lua customization. It
   returns each child Application's own `.status.health`, allowing health to propagate
   recursively through `root-app` → `platform` → operator Applications.

3. **`SkipDryRunOnMissingResource=true`** on workload Applications whose CRs depend on
   CRDs installed by a different app: `eurotransit`, `eurotransit-kafka`,
   `eurotransit-data`. Keep this as defense in depth: the branch-validation bootstrap
   applies leaf Applications directly, and Kubernetes API discovery/webhook readiness
   can still have short registration delays. The sync retries instead of hard-failing
   until the resource is accepted.

4. **Compensating control:** a `kubeconform` schema-validation step (`just helm-schema`,
   wired into CI) to recover the validation safety that `SkipDryRunOnMissingResource`
   gives up — a typo'd `kind`/`apiVersion` should fail a PR, not be silently treated as
   a missing CRD that retries forever.

### Cross-Application ordering is health-gated

The app-of-apps uses `sync-wave: "0"` on `platform` and `"1"` on `workloads`, and finer
waves inside them. Sync waves always order resources within a single Application, but
child Applications need an explicit health assessment for the earlier wave to remain
blocked while they reconcile. Decision **2** restores that assessment:

- `root-app` waits for its wave `-1` `argocd` Application to become Healthy;
- it then creates the wave `0` `platform` Application and waits for it to become Healthy;
- the `platform` Application recursively waits for its wave `0` operator Applications
  before applying its wave `1` CRs;
- only after `platform` is Healthy does `root-app` create the wave `1` `workloads`
  Application.

The same customization is present in the one-time Kustomize seed, so it is active before
`root-app` is first applied on a fresh cluster. `SkipDryRunOnMissingResource` remains a
fallback rather than the primary ordering mechanism.

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
  - **Validation is already recovered** by the `kubeconform` control (decision 4), so the main
    benefit of CRD-first (keeping downstream dry-run) is largely redundant here.
  - **When it would be worth it:** many teams/apps sharing CRDs under strict change management —
    not a single-cluster, five-person capstone. Revisit only if health-gated ordering plus the
    retry fallback proves insufficient.
- **`Replace=true`** to sidestep the annotation-size limit. Rejected: it is destructive
  (deletes and recreates resources) and risky for CRDs holding live CRs.
- **Leave Argo CD's default Application health behavior and describe cross-app waves as
  hints only.** Rejected: the hierarchy is deliberately split into platform and workload
  dependency tiers. The documented health customization is small and lets the declared
  waves enforce that intent instead of relying primarily on timing and retries.
- **Rely on retries alone.** Rejected as the primary mechanism: cases 9–10 showed that
  racing another app's CRD/controller installation produces noisy failed syncs and can
  wedge bootstrap. Retry remains a defense-in-depth fallback.

## Consequences

- **Easier:** a fresh cluster bootstraps in explicit dependency order. An unhealthy
  operator blocks the workload wave rather than allowing dependent CRs to race ahead.
- **Harder / risk:** `SkipDryRunOnMissingResource` weakens validation — a genuinely
  wrong `kind`/`apiVersion` is treated as "missing CRD, will retry" rather than failing
  loudly. Blast radius is limited (built-in kinds still get full dry-run), and the
  `kubeconform` control is the mitigation. `ServerSideApply` changes field-ownership
  semantics; it is the recommended mode for operator charts, but field-manager conflicts
  can appear if the same fields are edited out of band.
- **Harder / risk:** health gating is fail-closed. A genuinely unhealthy platform
  Application now holds later waves indefinitely, which is safer but makes the blocking
  child health status part of bootstrap diagnosis. The Lua customization mirrors Argo
  CD's documented implementation and must be rechecked when Argo CD is upgraded.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance during the EM-31 platform-bootstrap work. Before ratifying:

- [ ] Confirm the four operator apps reach Synced+Healthy on a fresh cluster with
      `ServerSideApply=true` (CRDs install).
- [ ] Hold one platform child Application in Progressing/Degraded and confirm
      `workloads` is not created/synced until that child becomes Healthy.
- [ ] Confirm the three workload apps converge (their CRs apply once CRDs exist).
- [ ] Confirm `just helm-schema` (kubeconform) runs in CI and fails on a deliberately
      broken manifest.
- [x] Strict CRD-first ordering evaluated and rejected (2026-07-09); eventual-consistency
      via `SkipDryRunOnMissingResource` remains the fallback (see Alternatives).

## References

- `docs/agent-log.md` cases 8 (kubeVersion), 9 (CNPG webhook readiness), 10 (cross-app CRD sync-wave).
- Argo CD sync options: `ServerSideApply`, `SkipDryRunOnMissingResource`.
- [Argo CD resource health — restoring `Application` health for app-of-apps wave
  gating](https://argo-cd.readthedocs.io/en/release-3.5/operator-manual/health/#argocd-app).
- CLAUDE.md — GitOps delivery rules; agentic-coding policy.
