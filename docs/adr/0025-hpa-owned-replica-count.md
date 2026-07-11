# ADR 0025 — HPA-managed Deployments omit `spec.replicas` (the HPA owns the replica count)

- **Status:** Proposed
- **Date:** 2026-07-11
- **Deciders:** Vojtech (delivery owner)
- **Context tags:** delivery, resilience, gitops
- **Supersedes / Superseded by:** — (refines ADR 0023)

---

## Context

ADR 0023 added HPAs for inventory and payments (catalog already had one), but the
Deployment templates kept `replicas: {{ .Values.<svc>.replicaCount }}`. That leaves two
controllers claiming the same field: the HPA scales `spec.replicas` at runtime, while Argo CD
— with `selfHeal: true` and no `ignoreDifferences` on the `eurotransit` Application — enforces
the rendered manifest's `replicas: 2`.

The conflict is latent today only because the HPAs have never left `minReplicas` (measured CPU
is 3–8% of requests). The moment an HPA scales inventory to 3 under k6 load or a chaos run,
Argo CD sees drift and scales it back to 2; the HPA scales up again, and the two controllers
fight exactly when the extra capacity is needed (CE-4 is the likely first trigger).

Found on 2026-07-11 while diagnosing the stuck Kafka broker-0 roll (node CPU-request
saturation, fixed separately by the 150m→100m CPU request trim in the same PR — documented
inline in `values.yaml` per the #46 convention). Reviewing what `replicaCount` was for
surfaced the ownership conflict.

## Decision

For every Deployment that has an HPA (catalog, inventory, payments):

1. **Omit `spec.replicas` from the Deployment template.** The HPA is the sole owner of the
   replica count at runtime.
2. **Remove `replicaCount` from that service's `values.yaml` entry.** The availability
   baseline is expressed once, as `hpa.minReplicas` (2 for all three, per ADR 0021).

Services without an HPA (orders, notifications) keep `replicaCount` and the rendered
`spec.replicas`.

## Alternatives considered

- **`ignoreDifferences` on `/spec/replicas` + `RespectIgnoreDifferences=true` sync option.**
  Works and avoids the one-time re-apply caveat below, but adds per-kind exception config to
  the Application and keeps a misleading `replicas:` in the manifests that a fresh install
  would still apply. Omitting the field states the ownership directly in the chart.
- **Disable `selfHeal` for the app.** Rejected outright — violates the GitOps invariant
  (constraint 2 in the delivery-owner charter).
- **Keep the pin and accept the fight.** Rejected: it silently caps every HPA at
  `minReplicas`, defeating the scale-out decision (ADR 0023).

## Consequences

- HPA scale-out works and Argo CD stays Synced while replicas move within
  `[minReplicas, maxReplicas]`.
- One less knob: the baseline lives only in `hpa.minReplicas`; no risk of `replicaCount`
  and `minReplicas` drifting apart.
- **One-time rollout caveat:** removing a field that was in the last-applied configuration
  deletes it from the live object, so on the first sync each of the three Deployments
  defaults to `replicas: 1` until the HPA reconciles it back to `minReplicas: 2` (one HPA
  sync period, ~15 s). That is a transient capacity dip of one pod per service, not an
  outage — merge while no demo, load test, or chaos experiment is running.
- Fresh installs briefly start at 1 replica until the HPA acts — same shape as the caveat
  above, acceptable for this project.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance (the fix and this ADR). Before ratification the team must verify:

- [ ] `kubectl get hpa -n eurotransit` shows all three HPAs `ABLE TO SCALE` after the sync
- [ ] After the first sync, all three services return to 2/2 ready within ~1 minute
- [ ] Under k6 load, an HPA scale-out above 2 does **not** flip the `eurotransit` Application
      to OutOfSync (this is the actual bug being fixed)
- [ ] `docs/agent-log.md` Case 16 recorded (the original agent omission)

## References

- ADR 0023 — HPA for contended services, topology spread, PDB completion
- ADR 0021 — HA replicas and RTO/RPO — source of the 2-replica baseline
- Argo CD docs: *Leaving room for the HorizontalPodAutoscaler* (auto-sync + HPA guidance)
- `docs/agent-log.md` Case 16
