# ADR 0008 — Single Helm chart for all five services

- **Status:** Proposed
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** delivery, helm, gitops
- **Supersedes / Superseded by:** —

---

## Context

EuroTransit ships five services (catalog, orders, inventory, payments, notifications)
onto one cluster via Argo CD. Their Kubernetes manifests can be packaged either as **one
umbrella Helm chart** covering all five, or as **five per-service charts**. This choice
shapes how CI writes image tags, how many Argo CD Applications exist, and the rollback
granularity — so it is recorded rather than left implicit.

This decision was formalized retroactively: the single-chart layout has been in use since
EM-14, but the trade-off lived only in the delivery-owner role notes.

## Decision

**One chart at `deploy/charts/eurotransit/`** covers all five services. One `values.yaml`
(CI bumps `<service>.image.tag`), one Argo CD Application (`eurotransit`), one place to
change shared defaults (probes, lifecycle, NetworkPolicy — see ADR 0002).

## Alternatives considered

- **Five per-service charts + five Argo CD Applications.** Gives independent rollback
  granularity and clean per-service ownership, but costs 5× template boilerplate, five
  Applications to wire, and a CI job that updates five charts. Rejected: at a 5-person team
  on one repo with a tight timeline, the overhead is not justified.
- **One chart, but a `values.yaml` per service.** Marginal isolation gain, same Application
  count; rejected as needless fragmentation of a single source of truth.

## Consequences

**Easier:**
- CI stays simple — one commit per build bumps one file.
- Shared config (probes, graceful shutdown, NetworkPolicy) is defined once via Helm helpers.
- One Application to watch for Synced/Healthy.

**Harder / risks:**
- **Coarser rollback by default** — reverting the whole chart. Mitigated: single-service
  rollback still works by reverting just that service's `image.tag` line in `values.yaml`.
- **No per-service Application ownership** — all five share one sync/health lifecycle; a
  broken template can fail the whole Application's render. Mitigated by `just helm-verify`
  pre-merge.
- Revisit if the team later needs independent release cadence per service.

## Verification & ownership (agentic-coding policy)

- [ ] Confirm the team accepts coarser default rollback granularity for CI/ops simplicity.
- [ ] Confirm single-service rollback (revert one `image.tag`) is exercised at least once.

## References

- `.agent/agents/delivery-owner.md` — original single-chart rationale.
- ADR 0002 — shared probe/lifecycle values that this chart centralizes.
- `deploy/charts/eurotransit/` — the chart.
