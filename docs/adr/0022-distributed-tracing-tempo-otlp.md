# ADR 0022 — Distributed tracing: Tempo + OpenTelemetry over OTLP (decision D10)

- **Status:** Proposed (this PR is the ratification vehicle for decision D10)
- **Date:** 2026-07-11
- **Author:** @giova95 (observability & verification)
- **Related:** RED/USE dashboards (#33); chaos experiment reports ("observe on our own
  dashboards"); app-repo PR "feat(tracing): OTLP span export"

## Context

The capstone requires distributed tracing across the money path — "where did this order
spend its time, and where did it fail?" — spanning HTTP hops (gateway → Orders →
Payments) AND Kafka stages. Nothing was deployed; the apps however already carried
`micrometer-tracing-bridge-otel`, so only the exporter, the backend, the Grafana
datasource and the network path were missing.

## Decision

1. **Backend: Grafana Tempo**, single-binary chart, pinned (1.10.1), in `monitoring`.
   Rationale vs Jaeger: native Grafana integration (one pane with RED/USE dashboards),
   object-storage architecture with a tiny single-binary mode that fits the 6 vCPU
   budget, and the Grafana stack is already our observability home.
2. **Instrumentation: what's already on the classpath** — Micrometer Tracing with the
   OTel bridge + `opentelemetry-exporter-otlp` (Boot-BOM-managed). No agents, no
   sidecars. W3C trace context propagation.
3. **Kafka propagation is explicit**: `spring.kafka.template/listener
   observation-enabled=true` (and `isObservationEnabled` in code for the custom
   notifications factory, where the Boot property does not reach). Without this, each
   service would start a NEW trace and the money-path question would be unanswerable.
4. **Sampling 100%** (`probability: 1.0`): course traffic is tiny; chaos analysis and
   the oral demo need every trace. Revisit only if storage cost ever matters.
5. **Network path is part of desired state**: the app namespace runs default-deny
   egress, so a dedicated NetworkPolicy (`eurotransit-allow-egress-tracing`, port 4318
   toward `monitoring`) ships with the chart — without it spans would be dropped
   *silently*, the worst failure mode for an observability signal.
6. **Retention 48h, no persistence yet** — same trade-off (and same D13 fix) as
   Prometheus storage: add a PVC before the demo cluster.

## Consequences

- Grafana gains a `Tempo` datasource (uid `tempo`, declared in
  kube-prometheus-stack.yaml, GitOps-managed like everything else).
- The `platform` AppProject's `sourceRepos` gains the pinned Grafana chart repo —
  applying the agent-log case 14 lesson *in the same PR* as the Application that
  needs it.
- CE-1/CE-2 reports can now attach traces ("the order stalled in the authorize span
  while the breaker was open") in addition to metrics.
- Coroutine bridges (`runBlocking` consumers) may occasionally produce imperfect
  parent-child links across the coroutine boundary; the HTTP and Kafka spans that
  answer the money-path question are unaffected. Known, accepted.

## Alternatives considered

- **Jaeger**: mature, but a separate UI and a heavier all-in-one; no advantage given
  our Grafana-centric stack.
- **OpenTelemetry Collector in between**: adds a buffering/fan-out layer we do not
  need at this scale; direct OTLP to Tempo keeps the moving parts minimal. Revisit if
  we ever need tail-based sampling or multi-backend export.
