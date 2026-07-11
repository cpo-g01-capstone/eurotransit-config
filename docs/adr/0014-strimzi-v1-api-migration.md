# ADR 0014 — Migrate Kafka CRs to the `kafka.strimzi.io/v1` API

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** kafka, strimzi, gitops, argocd
- **Supersedes / Superseded by:** —

---

## Context

The Strimzi operator was pinned to `quay.io/strimzi/operator:1.1.0` (ADR 0004,
`platform/strimzi/strimzi.yaml`). That operator installs Kafka CRDs that serve **only
`kafka.strimzi.io/v1`** — `v1beta2` has been removed:

```
$ kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{.spec.versions[*].name}'
v1        # v1beta2 is no longer served
```

The manifests under `kafka/` (`kafka-broker.yaml`, `kafka-topics.yaml`) still declared
`apiVersion: kafka.strimzi.io/v1beta2` — the operator bump wasn't carried through to the
CRs. Result: the `eurotransit-kafka` Argo CD Application (`apps/kafka.yaml`) could not
apply and sat **OutOfSync / Missing**:

```
SyncError: resource mapping not found for name "eurotransit-kafka" ...
  no matches for kind "Kafka" in version "kafka.strimzi.io/v1beta2"
  ensure CRDs are installed first (retried 5 times)
```

Because the whole `Kafka`, `KafkaNodePool`, and five `KafkaTopic` resources failed to
apply, **no Kafka broker existed in the cluster**. Every application service that gates
readiness on the Kafka bootstrap endpoint therefore could not become Ready — the async
pipeline had no backbone.

The `SkipDryRunOnMissingResource=true` option already on the app makes Argo *tolerate* a
not-yet-registered CRD (so it retries rather than hard-failing on first sync), but it
cannot help when the CRD **is** registered and simply doesn't serve the requested API
version. That is a manifest correctness problem, not an ordering problem.

## Decision

Change the `apiVersion` of every Strimzi custom resource in `kafka/` from
`kafka.strimzi.io/v1beta2` to `kafka.strimzi.io/v1`:

- `kafka/kafka-broker.yaml` — `KafkaNodePool` (`dual-role`) and `Kafka` (`eurotransit-kafka`)
- `kafka/kafka-topics.yaml` — all five `KafkaTopic` CRs

This is a **version-string-only** change. The `v1` OpenAPI schema was checked against the
live CRD and accepts every field already in use unchanged:

- `Kafka.spec`: `kafka` (`version`, `listeners`, `config`), `entityOperator`
- `KafkaNodePool.spec`: `replicas`, `roles`, `storage`
- `KafkaTopic.spec`: `partitions`, `replicas`, `config`

The canonical Kafka pattern in `.agent/agents/delivery-owner.md` is updated to emit `v1`,
with a note about why, so agent-generated manifests stop reintroducing `v1beta2`.

## Alternatives considered

- **Downgrade the operator to a `v1beta2`-serving version (rejected).** Would undo the
  ADR 0004 pin and the Kafka 4.2.0 / KRaft baseline the CR already targets. Chasing an old
  API to avoid a one-line change is backwards.
- **Rely on `SkipDryRunOnMissingResource` / a conversion webhook (insufficient).** The
  skip option addresses CRD *registration* timing, not a dropped API version; Strimzi
  serves `v1` directly with no conversion path from a `v1beta2` client request.
- **Leave Kafka undeployed for now (rejected).** The async pipeline (`order-placed` →
  … → `notification-requested`) is core to the project; several services can't reach
  readiness without a broker.

## Consequences

**Easier / better:**
- `eurotransit-kafka` can sync; the broker, node pool, and topics get created; the async
  pipeline has a backbone again.
- Manifests now match the pinned operator's served API — no version drift.
- The agent guide no longer teaches the dead version, closing the loop that caused this.

**Harder / risks:**
- **Coupled to the operator version.** `v1` is what `operator:1.1.0` serves; if the
  operator pin ever changes, re-verify the served version (`kubectl get crd
  kafkas.kafka.strimzi.io -o jsonpath='{.spec.versions[*].name}'`).
- **Does not by itself fix service readiness.** Kafka coming up is necessary but not
  sufficient — orders/inventory also have outstanding DB-wiring issues (tracked
  separately); this ADR only unblocks the Kafka layer.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] `kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{.spec.versions[*].name}'`
      returns `v1` (and confirm `kafkanodepools`, `kafkatopics` likewise).
- [ ] Server dry-run the converted manifests: `kubectl apply --dry-run=server -f kafka/`
      applies cleanly with no schema errors.
- [ ] After merge, `eurotransit-kafka` goes **Synced / Healthy** and
      `kubectl get kafka,kafkanodepool,kafkatopic -n eurotransit` shows the broker Ready
      and all five topics created.
- [ ] Confirm the operator pin (`platform/strimzi/strimzi.yaml`) is unchanged — this ADR
      changes CR manifests only, not the operator.

## References

- [ADR 0004 — Operator Version Pinning](0004-operator-version-pinning.md)
- `apps/kafka.yaml` — the `eurotransit-kafka` Argo CD Application (`path: kafka`)
- `.agent/agents/delivery-owner.md` — Kafka topic CR canonical pattern (updated to `v1`)
- Strimzi API graduation to `v1`: <https://strimzi.io/docs/operators/latest/>
