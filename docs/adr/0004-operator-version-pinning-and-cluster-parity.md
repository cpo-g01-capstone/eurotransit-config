# ADR 0004 — Operator version pinning and dev/prod cluster parity

- **Status:** Proposed
- **Date:** 2026-07-01
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** platform, gitops, kafka
- **Supersedes / Superseded by:** —

---

## Context

EM-31 pins every platform operator to an explicit chart version (no floating `HEAD`).
Pinning only makes sense against a **target Kubernetes version**, and the project runs
on **two** control planes:

- **AKS `aks-eurotransit-g01` — k8s 1.34.8.** The real, graded deliverable; the demo runs here.
- **k3d — local.** Exists only to iterate without incurring Azure cost.

The original pins were chosen the wrong way round: k3d was pinned to **k8s 1.29.15**
specifically to stay under **Strimzi 0.40.0**'s support ceiling (~1.29), and AKS 1.34 was
left unaddressed. That makes the obsolete operator the constraint and the graded cluster
an afterthought — one pin set that cannot satisfy a 1.29 dev cluster and a 1.34 prod
cluster at once. Strimzi 0.40.0 (early 2024) will very likely fail on 1.34 (removed/renamed
APIs, webhook incompatibilities).

## Decision

1. **AKS 1.34 is the authoritative target.** All operator pins must support k8s 1.34.
   k3d is bent to match, never the reverse.

2. **k3d is pinned to k8s 1.34 for exact parity** (`rancher/k3s:v1.34.x-k3s1`). The whole
   value of the local cluster is catching bootstrap/sync-wave/CRD problems before they hit
   the paid cluster; a version gap reintroduces "works on k3d, breaks on AKS" surprises.
   Parity is free once every pin already supports 1.34.

3. **Strimzi is bumped 0.40.0 → chart/operator 1.1.0** (tested k8s 1.30–1.36; covers 1.34
   with headroom on both ends). Chosen over the 0.5x line because the bootstrap is
   greenfield (no in-place upgrade risk) and 1.1.0 gives the widest ceiling (1.36) against
   a future AKS auto-upgrade. This is a **delivery-lane decision, not a team decision** —
   it is a k8s-compatibility fact, not a product choice like an SLO.

4. **The Kafka broker version bumps with it: `3.7.0 → 4.2.0`** (Strimzi 1.1.0 ships Kafka
   4.2.0 default, 4.2.1, 4.3.0; 3.7.0 is no longer shipped). 4.2.0 is the tested default;
   4.3.0 offers no benefit on a fresh cluster. The existing Kafka CR is already
   KRaft + `KafkaNodePool`, so the risky ZooKeeper→KRaft migration is a non-issue.

5. **A single version pin, one source of truth.** The Strimzi version must be bumped in
   **both** the GitOps Application (`platform/strimzi/strimzi.yaml`) **and** the Justfile
   manual-path constant (`STRIMZI_VERSION`, line 13) — leaving the constant at 0.40.0 would
   silently install a 1.34-incompatible operator via the escape hatch. The manual path is
   retained (it is the only way to test *unpushed* manifests; `bootstrap-branch` needs a
   pushed branch), but the dual pin is a known smell: follow-up to have the Justfile read
   versions from the manifests (as `platform-verify` already does).

### Coupled edits (all three must land together)

| Edit | File | From → To |
|---|---|---|
| Operator chart | `platform/strimzi/strimzi.yaml` | `0.40.0 → 1.1.0` |
| Kafka broker | `kafka/kafka-broker.yaml` | `version: 3.7.0 → 4.2.0` |
| Manual-path pin | `Justfile` `STRIMZI_VERSION` | `0.40.0 → 1.1.0` |
| k3d k8s | `k3d-config.yaml` | `v1.29.15 → v1.34.x-k3s1` |

## Alternatives considered

- **Keep k3d at 1.29 to protect Strimzi 0.40.** Rejected — tail wagging the dog; strands the
  graded AKS cluster on an operator that won't run there.
- **Stay on the Strimzi 0.5x line** (e.g. 0.51.0, k8s 1.30–1.35) to keep a 3.x Kafka broker.
  Rejected — buys a marginally smaller Kafka-client-compat surface at the cost of a shorter
  k8s ceiling and an operator nearer EOL.
- **Deliberate k3d↔AKS version gap** ("close enough" at 1.30/1.31). Rejected — reintroduces
  the exact drift class the local cluster exists to eliminate.
- **Retire the manual bootstrap path** for GitOps purity (single source of truth). Deferred —
  it has real offline/pre-push value; drift is instead killed by making it read the manifests.

## Consequences

- **Easier:** one pin set spans both clusters; local k3d faithfully reproduces the AKS API
  surface; a future AKS upgrade to 1.35/1.36 needs no operator change.
- **Harder / risk:** the Kafka broker jumps two majors (3.7 → 4.2). Modern `kafka-clients`
  (≥3.1, ideally 3.7+) talk to a 4.2 broker fine, but the five services own their client
  version — an **[app team]** confirmation is required (tracked alongside the ACR-image
  blocker; **no ACR images exist yet**, so this is not yet exercised).
- **Out of scope but surfaced:** the Kafka CR is `storage: type: ephemeral`, single broker.
  Fine for k3d dev; on the graded AKS cluster it means guaranteed data loss on broker restart
  and makes chaos experiment #4 (Kafka partition / "nothing lost") undemonstrable. Docketed to
  the Tier 2 (AKS) PR: persistent-claim storage (delivery decision) + broker count (**[team]**,
  coupled to chaos #4).

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance during EM-31. Before ratifying:

- [ ] Confirm Strimzi 1.1.0 chart version exists on `https://strimzi.io/charts/` and renders
      via `just platform-verify`.
- [ ] Confirm Kafka 4.2.0 is accepted by the 1.1.0 operator (Kafka CR reaches Ready on k3d 1.34).
- [ ] Re-run `just helm-verify` + `just platform-verify` after all four coupled edits.
- [ ] Tier 1 (k3d 1.34) gate green — see the merge-gate checklist in `TODO.local.md`.
- [ ] **[app team]** confirm `kafka-clients` ≥ 3.1 against a 4.2 broker.

## References

- ADR 0001 (AKS sizing/budget — constrains Kafka broker count), ADR 0003 (sync options).
- Strimzi downloads / compatibility: <https://strimzi.io/downloads/>; release 1.1.0 notes.
- `TODO.local.md` — merge-gate (Tier 1/Tier 2) and Tier 2 Kafka-storage docket.
