# ADR 0026 — Progressive delivery: Orders canary + Catalog blue/green (D6/D7)

- **Status:** Accepted (team decisions D6 and D7 ratified 2026-07-11)
- **Date:** 2026-07-11
- **Deciders:** whole team (thresholds and cleanup window are team-owned decisions
  per the agentic coding policy; the manifests implement them)
- **Related:** ADR 0018 (SLOs are the reference the gate must beat), ADR 0023/0025
  (HPA/replica ownership), `docs/delivery/progressive-delivery-runbook.md`

## Context

The capstone requires BOTH progressive delivery patterns demonstrated on top of the
GitOps loop: a canary (fraction of traffic, SLI-gated promotion) and a blue/green
switch (instant cutover, fast rollback). Until T6:

- a weighted `TraefikService` existed for Orders, **but the IngressRoute did not
  reference it** — `/api/orders` pointed straight at the Service, so adjusting the
  weights was dead config and a "canary" would have silently served 100% stable.
  (Found during T6 implementation; same *present-but-not-wired* failure class as
  the audit's BUG-1.)
- there was no canary Deployment/Service, no values plumbing, and no blue/green
  resources at all.

## Decision

**Canary on Orders (the money path — where a bad rollout costs the most):**

- `/api/orders` **always** routes through `eurotransit-orders-weighted`; with the
  canary disabled the stable arm gets weight 100. No route flapping between
  rollouts and the wiring can never regress to dead config again.
- The canary track (`Deployment` + `Service` + dedicated `ServiceMonitor`) renders
  only while `orders.canary.enabled=true`. Weights, tag and enablement live in
  `values.yaml`: **a rollout is a sequence of Git commits**, reviewable and
  revertible like everything else.
- The canary joins the same Kafka consumer group as stable ON PURPOSE: the
  candidate must prove the whole money path (HTTP entry + Kafka stages), not just
  the controller.
- **D6 promotion gate (ratified):** canary error rate **< 1%** AND p95 **< 300 ms**
  sustained for **5 minutes**, measured on the canary's own metrics. Deliberately
  stricter than the checkout SLO (99.5% / 500 ms): a promotion gate vouches for a
  *novelty* and needs margin between "the candidate looks fine" and "we are
  violating the contract". Alert-free burn rate during the window is an implicit
  extra condition.

**Blue/green on Catalog (stateless, read-only — a zero-risk switch to demo):**

- The green track deploys alongside blue (`catalog.blueGreen.enabled=true`); the
  **switch happens at the IngressRoute**, which serves the Service of
  `catalog.blueGreen.activeTrack`.
- Ingress-level switch instead of Service-selector surgery because (a) a
  Deployment's selector is immutable — mutating label schemes on live Deployments
  is exactly the failure class we hit with Tempo (see the #53 runbook), and
  (b) overlapping Deployment selectors are undefined behaviour. Two independent
  Deployments with distinct labels, one routing decision.
- **D7 cleanup window (ratified):** after the switch, the old track keeps running
  for **5 clean minutes** (one full observation cycle on the dashboards) as the
  instant-rollback path; then it is removed (promote the tag to the blue track,
  disable green — one commit). If anything degrades within the window, rollback =
  revert the switch commit; Traefik cutover is immediate.

**Accepted trade-offs:**

- The canary/green Deployment manifests **duplicate** the stable ones (lockstep
  comment on both sides) instead of sharing a Helm partial. A shared template
  would touch the production manifests of every service for a demo-scoped
  feature; the drift risk is bounded by the lockstep comments and by review.
- Both tracks are **off by default**: a second money-path pod is real budget on
  6 vCPU (ADR 0001). Enabling a track is part of the rollout commit.
- The catalog HPA targets only the blue track; green runs pinned replicas for its
  short life.

## DORA delivery strategies — why not the other two on the critical path

The four canonical strategies and where they land for EuroTransit:

- **All-at-once (recreate):** kill old, start new — a window where NOTHING serves.
  On the money path that is a self-inflicted outage per deploy; the checkout SLO
  (99.5%) would burn its monthly error budget in a handful of deploys. Acceptable
  only where a gap is invisible (we effectively accept it for the demo-scoped
  green track teardown, which serves no traffic by then).
- **Rolling update:** no downtime, but during the roll BOTH versions serve 100% of
  traffic mixed, with no traffic-fraction control and no SLI gate deciding
  progression — Kubernetes advances on *readiness*, which proves "the pod boots",
  not "the version is correct" (a wrong-but-healthy candidate rolls to 100%).
  It is the right default for low-risk surfaces — and it IS what our Deployments
  do for routine image bumps on non-entry services — but it cannot host a
  promotion decision.
- **Canary:** bounded blast radius (10% of requests see the candidate), an
  explicit SLI-gated promotion decision (D6), cheap abort. The right shape for
  the Orders money path, where correctness regressions (not crashes) are the
  real risk.
- **Blue/green:** full parallel capacity, instant atomic cutover and instant
  rollback, at the cost of double resources and no gradual exposure. The right
  shape for Catalog: read-only, cache-backed, where "serve the old version 30 s
  longer" is free but a mixed-version window is confusing to demo.

In DORA terms: deployment frequency and lead time come from the GitOps pipeline
itself; the two chosen strategies buy down **change failure rate** (SLI gate) and
**time to restore** (instant rollback paths) exactly where failures are most
expensive.

## Consequences

- A canary rollout and a blue/green switch are each ~3 small commits, all
  reviewable, all revertible; the runbook scripts them step by step.
- The weighted TraefikService is now load-bearing (the IngressRoute depends on
  it) — a regression to "dead config" would break `/api/orders` visibly instead
  of silently.
- Two more conditional resources to keep in lockstep with their stable twins —
  bounded by comments and review, revisit if a third track ever appears.
