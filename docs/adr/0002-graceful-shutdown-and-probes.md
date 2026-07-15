# ADR 0002 — Graceful Shutdown and Probe Configuration

- **Status:** Proposed (awaiting team ratification)
- **Date:** 2026-06-29
- **Deciders:** _<add team members>_
- **Context tags:** delivery, resilience, helm, probes, Pillar A, Pillar C
- **Supersedes / Superseded by:** —

---

## Context

Pods are killed routinely — rollouts, `selfHeal` reconciliation, HPA scale-down, node
drain, and chaos experiment #2 (Pod kill → Inventory mid-reservation). On the money path
(Orders → Inventory/Payments → Kafka → Notifications) an abrupt kill drops in-flight
requests and can orphan async work. The capstone requires us to **demonstrate** (not claim)
that in-flight work finishes or is cleanly cancelled on shutdown, with no double-processing
and no traffic dropped during drain.

Two cross-cutting concerns must be configured consistently across all five services:

1. **Graceful shutdown** — on SIGTERM the JVM must drain in-flight work before exiting, and
   traffic must stop reaching the Pod *before* it dies.
2. **Probes** — liveness must never depend on a downstream (a liveness probe that checks
   Kafka/DB causes cascading restarts when a downstream is merely slow), while readiness
   must gate traffic and reflect the draining state.

These values were previously correct but **hardcoded and duplicated** across the five
Deployment templates, violating the project rule that template values live in `values.yaml`.

## Decision

Centralize graceful-shutdown and probe configuration in `values.yaml` and apply it uniformly
to all five services via Helm helpers.

**Graceful shutdown (`lifecycle` values + `eurotransit.preStop` helper):**

- `terminationGracePeriodSeconds: 60`
- `preStopSleepSeconds: 5` — a `preStop` `sleep` so kube-proxy and Traefik finish removing
  the Pod from Service endpoints *before* SIGTERM lands, so no in-flight request is dropped.
- `shutdownTimeout: "50s"` → Spring `spring.lifecycle.timeout-per-shutdown-phase`, draining
  in-flight work before the JVM exits.
- **Invariant:** `preStopSleepSeconds + shutdownTimeout < terminationGracePeriodSeconds`
  (5 + 50 = 55 < 60). Must hold if the numbers are tuned.

**Drain → traffic-stop chain (relies on Kubernetes endpoints, no extra Traefik config):**

1. Pod enters `Terminating` → removed from the Service's ready endpoints → Traefik stops
   routing new traffic.
2. `preStop` sleep keeps the container alive while that removal propagates.
3. SIGTERM → Spring graceful shutdown drains and flips readiness to `OUT_OF_SERVICE`.
4. JVM exits before the grace period elapses.

**Probes (`probes` values + `eurotransit.probes` helper):**

| Probe | Endpoint | Checks | Timings |
|---|---|---|---|
| startup | `/actuator/health/liveness` | local process | `failureThreshold: 20`, `periodSeconds: 10` |
| liveness | `/actuator/health/liveness` | **local process only — never downstream** | `periodSeconds: 15`, `failureThreshold: 3` |
| readiness | `/actuator/health/readiness` | internal readiness state; reports draining on shutdown — **not** Kafka/DB (see amendment) | `periodSeconds: 5`, `failureThreshold: 3` |

Settings are **shared/global** across services for now; per-service overrides can be added
later (e.g. a longer `shutdownTimeout` for Orders/Payments if chaos testing shows the money
path needs more drain time).

## Alternatives considered

- **Keep values hardcoded per Deployment** — rejected: duplicated across 5 files, drift-prone,
  and against the project's "template values live in `values.yaml`" rule.
- **Per-service lifecycle/probe blocks from day one** — rejected for now: 5× boilerplate with
  no current evidence the services need different timings. Revisit if chaos testing demands it.
- **Liveness on `/actuator/health` (full health, includes DB/Kafka)** — rejected outright:
  known agent failure mode; a slow downstream would trigger cascading restarts.
- **Extra Traefik-side health checks / `publishNotReadyAddresses`** — unnecessary: Traefik's
  Kubernetes provider already drains via endpoint removal; the `preStop` sleep covers
  propagation lag.

## Consequences

**Positive**
- One place to tune drain/probe behaviour; all five services stay consistent by construction.
- Behaviour-preserving refactor — rendered manifests are byte-identical to the prior literals.
- The `helm-verify` offline gate (lint + template + Azure overlay render) covers the helpers.
- Liveness-vs-readiness split is enforced uniformly, satisfying the Pillar C probe rule.

**Negative / risks**
- The `preStop` hook uses `/bin/sh`/`sleep`; a shell-less (distroless) image would break it.
  Current Spring Boot JRE images include a shell — re-check if the base image changes.
- Graceful drain only works if the **apps** set `server.shutdown=graceful` and enable the
  readiness health group. That is application-repo config, outside this chart.
- Global timings may be too short for a service with long in-flight work; mitigated by the
  per-service override path.

## Verification & ownership (agentic-coding policy)

This refactor was produced with agent assistance and **must be verified by the team**:

- [ ] Confirm each service sets `server.shutdown=graceful` and exposes readiness so it flips
      to `OUT_OF_SERVICE` during drain (application repo, Pillar A).
- [ ] Confirm the container base images include a shell for the `preStop` hook.
- [ ] Demonstrate under chaos experiment #2 (Pod kill mid-reservation): no dropped requests,
      no double-processing, readiness refuses traffic during drain.
- [ ] Decide whether Orders/Payments need a longer `shutdownTimeout` than the shared default.

## Amendment (2026-07-15) — readiness does not check Kafka/DB

The probe table originally said readiness "checks Kafka/DB". That never matched the
implementation: the services enable the Actuator probe endpoints with Spring's **default**
health groups, so `/actuator/health/readiness` reflects only the application's internal
`ReadinessState` — flipped to `REFUSING_TRAFFIC` by each service's `GracefulShutdownManager`
during drain. DB/Kafka indicators are deliberately **not** wired into the readiness group,
a decision ratified in app-repo ADR 0004:

- a blip on a **shared** dependency would de-register every replica simultaneously —
  turning a partial failure into hard 503s at Traefik while doing nothing to heal the
  dependency, and dropping the endpoints Prometheus scrapes exactly when they're needed;
- during a CNPG failover (chaos experiment #5) readiness gating would flap pods out of
  endpoints *after* the failover already completed, inflating the observed RTO — confirmed
  by CE-5 runs: 0 restarts, no readiness flap, R2DBC pool reconnected on its own;
- DB/Kafka failures surface as symptoms (5xx → `CheckoutHighErrorRate`), consistent with
  the project's symptom-based alerting rule.

Startup ordering against the DB is covered separately: Flyway runs during context startup
(the app cannot become ready without having reached the DB once), and the CNPG-generated
credentials secret gates container start via `secretKeyRef`.

## References

- CLAUDE.md — Async lifecycle requirements (Pillar A); Probe rules (Pillar C); Common mistakes.
- docs/agents/vojtech.md — `terminationGracePeriodSeconds: 60` + 5s preStop; liveness local-only.
- ADR 0001 — AKS sizing (the cluster these workloads run on).
- Spring Boot reference — graceful shutdown, Actuator liveness/readiness probe groups.
