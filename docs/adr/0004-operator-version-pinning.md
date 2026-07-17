# ADR 0004 — Operator version pinning

- **Status:** Accepted (team ratification 2026-07-17 — pins in place (Strimzi 1.1.0, CNPG 0.29.0) and exercised in production since; parity framing retired by ADR 0006)
- **Date:** 2026-07-01 _(revised 2026-07-09 — cluster-parity framing retired, see below)_
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** platform, gitops, kafka
- **Supersedes / Superseded by:** The original title ("… and dev/prod cluster parity") and its k3d-parity clause were retired when [ADR 0006](0006-drop-k3d-azure-only.md) dropped k3d. The pinning decision below stands and is unchanged in substance.

---

## Context

The platform installs its operators (cert-manager, CloudNativePG, Strimzi,
kube-prometheus-stack, Traefik, Sealed Secrets) as Argo CD Applications sourced from upstream
Helm charts. Each Application's `targetRevision` can either **float** (`HEAD` / a moving minor)
or be **pinned** to an explicit chart version.

Pinning only makes sense against a **target Kubernetes version**. The cluster is **AKS
`aks-eurotransit-g01` — k8s 1.34.8** (the single, graded environment; ADR 0006 retired the
local k3d cluster). Two forces make pinning the right call:

1. **Determinism.** With `selfHeal: true`, Argo reconciles continuously. A floating
   `targetRevision` means a chart maintainer's release can land on the cluster on any resync,
   unannounced — the same commit no longer reconciles to the same state. GitOps only gives
   reproducible deploys if the version is pinned.
2. **No local safety net.** Since ADR 0006 there is **no k3d cluster** to catch a bad operator
   version before it reaches AKS. The only cluster is the graded one, so an unexpected float is
   a production incident, not a dev annoyance. Pinning is therefore *more* important post-k3d,
   not less.

The original pins were also chosen the wrong way round: Strimzi was pinned to **0.40.0**, whose
support ceiling (~k8s 1.29) predates AKS 1.34 — an early-2024 operator that will very likely
fail on 1.34 (removed/renamed APIs, webhook incompatibilities). The obsolete operator was the
constraint; the graded cluster was the afterthought. This ADR flips that.

> **Revision note (2026-07-09):** this ADR was originally "Operator version pinning **and
> dev/prod cluster parity**". The parity half — pin k3d to the same k8s version as AKS so
> "works locally" means "works on AKS" — was made obsolete by [ADR 0006](0006-drop-k3d-azure-only.md)
> (k3d removed). That clause (old point 2) and the k3d/Justfile coupled edits are struck; the
> operator-pinning decision is otherwise intact.

## Decision

1. **Pin every platform operator to an explicit chart version — no floating `HEAD`.** All pins
   must support **k8s 1.34** (the AKS version). `platform-verify` reads the pins straight from
   the Application manifests and confirms each chart version resolves and renders.

2. **Strimzi is pinned to chart/operator `1.1.0`** (tested k8s 1.30–1.36; covers 1.34 with
   headroom on both ends), up from 0.40.0. Chosen over the 0.5x line because the bootstrap is
   greenfield (no in-place upgrade risk) and 1.1.0 gives the widest ceiling (1.36) against a
   future AKS auto-upgrade. This is a **delivery-lane decision, not a team decision** — a
   k8s-compatibility fact, not a product choice like an SLO.

3. **The Kafka broker version bumps with it: `3.7.0 → 4.2.0`** (Strimzi 1.1.0 ships Kafka 4.2.0
   default, 4.2.1, 4.3.0; 3.7.0 is no longer shipped). 4.2.0 is the tested default; 4.3.0 offers
   no benefit on a fresh cluster. The Kafka CR is already KRaft + `KafkaNodePool`, so the risky
   ZooKeeper→KRaft migration is a non-issue.

4. **One pin, one source of truth.** Each operator version lives **only** in its GitOps
   Application manifest (e.g. `platform/strimzi/strimzi.yaml`). The former second copy — the
   `STRIMZI_VERSION` constant in the Justfile manual-bootstrap path — is gone: ADR 0006 removed
   the manual path entirely, so there is no longer a way to silently install a different version.

### Coupled edits (must land together)

| Edit | File | From → To |
|---|---|---|
| Operator chart | `platform/strimzi/strimzi.yaml` | `0.40.0 → 1.1.0` |
| Kafka broker | `kafka/kafka-broker.yaml` | `version: 3.7.0 → 4.2.0` |

## Alternatives considered

- **Float `targetRevision` (no pin).** Rejected — non-deterministic reconciles; with no local
  cluster (ADR 0006) an unexpected chart release breaks the only, graded cluster. Pinning is the
  point of reproducible GitOps.
- **Keep Strimzi 0.40.0.** Rejected — its ~1.29 k8s ceiling won't run on AKS 1.34; strands the
  graded cluster on an operator that won't start.
- **Stay on the Strimzi 0.5x line** (e.g. 0.51.0, k8s 1.30–1.35) to keep a 3.x Kafka broker.
  Rejected — a marginally smaller Kafka-client-compat surface at the cost of a shorter k8s
  ceiling and an operator nearer EOL.

## Consequences

- **Easier:** deterministic reconciles on the single AKS cluster — the same commit always
  installs the same operator versions; `platform-verify` catches a typo'd/yanked pin before Argo
  ever syncs it; a future AKS upgrade to 1.35/1.36 needs no operator change (headroom to 1.36).
- **Harder / risk:**
  - **Manual bumps.** Pinned versions don't pick up upstream security/patch releases
    automatically — someone must bump the pin deliberately. Acceptable: it's the price of
    determinism, and `platform-verify` makes a bump a one-line, validated change.
  - **Kafka broker jumps two majors (3.7 → 4.2).** Modern `kafka-clients` (≥3.1, ideally 3.7+)
    talk to a 4.2 broker fine, but the five services own their client version — an **[app team]**
    confirmation is required, exercised once app images are pushed to ACR (EM-32/EM-41).
- **Out of scope but surfaced:** the Kafka CR is `storage: type: ephemeral`, single broker. On
  the graded AKS cluster that means data loss on broker restart and makes chaos experiment #4
  (Kafka partition / "nothing lost") undemonstrable. Docketed: persistent-claim storage
  (delivery) + broker count (**[team]**, coupled to chaos #4).

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance during EM-31; refactored after ADR 0006. Before ratifying:

- [ ] Confirm every operator Application uses a fixed `targetRevision` (no `HEAD`) and
      `just platform-verify` passes.
- [ ] Confirm Strimzi 1.1.0 exists on `https://strimzi.io/charts/` and the Kafka CR (broker
      4.2.0) reaches Ready on AKS.
- [ ] Re-run `just helm-verify` + `just platform-verify` after the two coupled edits.
- [ ] **[app team]** confirm `kafka-clients` ≥ 3.1 against a 4.2 broker once ACR images exist.

## References

- [ADR 0006](0006-drop-k3d-azure-only.md) — dropped k3d (retires this ADR's parity framing).
- ADR 0001 (AKS sizing/budget — constrains Kafka broker count), ADR 0003 (Argo sync options).
- Strimzi downloads / compatibility: <https://strimzi.io/downloads/>; release 1.1.0 notes.
