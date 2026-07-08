# EM-31 — Version-Pinning Grilling Record

A design-tree walk of the EM-31 platform-bootstrap pinning decisions, stress-tested
question-by-question on 2026-07-01 (`/grill-with-docs`). This preserves the **reasoning**
behind the choices; the formal decision lives in [ADR 0004](../adr/0004-operator-version-pinning-and-cluster-parity.md)
and the action items in `TODO.local.md`.

**Owner:** @vojtech-n (delivery) · **Status:** decisions accepted, edits pending Tier 1 verification.

Legend: **Q** question · **Rec** recommended answer · **→** accepted decision.

---

## The design tree (root → leaves)

The whole pinning strategy hangs off one root question: *pins against which Kubernetes
version?* Everything below resolves in dependency order from there.

### 1. Which cluster is authoritative? (root)
- **Q:** k3d was pinned to k8s 1.29 to protect Strimzi 0.40; AKS is 1.34. One pin set can't
  satisfy both. Which cluster wins?
- **Rec:** AKS 1.34 — it's the graded deliverable; k3d only exists to avoid Azure cost.
- **→** **AKS 1.34 is authoritative. k3d bends to it, never the reverse.**

### 2. How closely should k3d track AKS?
- **Q:** With the 1.29 constraint gone, bump k3d to exact 1.34, or a "close enough" 1.30/1.31?
- **Rec:** Exact parity at 1.34 — the local cluster exists to catch problems *before* the paid
  one; a version gap reintroduces "works on k3d, breaks on AKS."
- **→** **k3d pinned to 1.34 (`rancher/k3s:v1.34.x-k3s1`).**

### 3. Which Strimzi version, and its ripples?
- **Q:** 0.40.0 won't run on 1.34. Which version, and is this a [team] call?
- **Rec:** Chart/operator **1.1.0** (k8s 1.30–1.36); declassify from [team] — it's a
  compatibility fact, not a product decision.
- **→** **Strimzi 1.1.0; delivery-lane decision.** Ripple surfaced: the Kafka CR's
  `version: 3.7.0` is no longer shipped by 1.1.0.

### 4. The Kafka broker jump (3.7 → 4.2) blast radius
- **Q:** 1.1.0 ships Kafka 4.2.0/4.2.1/4.3.0. Bump broker to 4.2.0? Does it break app clients?
- **Rec:** 4.2.0 (tested default). CR is already KRaft, so no ZooKeeper migration. Modern
  `kafka-clients` (≥3.1) talk to 4.2 fine → flag, don't block.
- **→** **Broker 4.2.0 + [app team] client-compat flag.** Noted: **no ACR images exist yet**,
  so client compat is untested until they do.

### 5. The pre-merge gate
- **Q:** Argo syncs `main` (lacks the stack) and no app images exist. What must be green
  before EM-31 merges?
- **Rec:** Two tiers — only the 5 app Deployments need ACR; everything else (operators, Kafka
  broker, Postgres, topics, issuer registration) proves on free k3d today.
- **→** **Tier 1 (k3d 1.34) gates the merge; Tier 2 (AKS: LB/DNS, real cert, app pods) is the
  next PR.** Cert issuance is NOT k3d-testable (HTTP-01 needs a public LB).

### 6. Keep or retire the manual bootstrap path?
- **Q:** The Justfile pins Strimzi separately (`STRIMZI_VERSION = 0.40.0`) — a second source of
  truth that would silently install a 1.34-incompatible operator.
- **Rec:** Keep the escape hatch (only way to test *unpushed* manifests), bump the constant to
  1.1.0, and later make the Justfile read versions from the manifests.
- **→** **Keep + bump + single-source follow-up.**

### 7. ClusterIssuer cross-app CRD dependency
- **Q:** The issuer's wave ordering is a hint; the real guarantee is
  `SkipDryRunOnMissingResource` + retry. Co-locate for determinism, or keep?
- **Rec:** Keep — the retry is the idiomatic Argo answer, idempotent, and no cert issues before
  the AKS LB exists anyway. (Manifest wording already states this precisely.)
- **→** **Keep the retry pattern.**

### 8. AKS Kafka topology/storage
- **Q:** The CR is `storage: type: ephemeral`, single broker. Fine on k3d; on the graded AKS
  cluster it means guaranteed data loss and makes chaos #4 undemonstrable.
- **Rec:** EM-31 bumps only `version`; docket persistent-claim storage (delivery) + broker count
  (**[team]**, coupled to chaos #4) to the Tier 2 PR.
- **→** **Docketed to Tier 2.** Trap flagged: demoing "Kafka recovers, nothing lost" on AKS while
  `type: ephemeral` is set is a silent contradiction a reviewer will catch.

---

## The sharpest catch

The Strimzi bump is **four coupled edits, not one** — miss any and the bootstrap breaks on the
new k3d:

| Edit | File | From → To |
|---|---|---|
| Operator chart | `platform/strimzi/strimzi.yaml` | `0.40.0 → 1.1.0` |
| Kafka broker | `kafka/kafka-broker.yaml` | `version: 3.7.0 → 4.2.0` |
| Manual-path pin | `Justfile` `STRIMZI_VERSION` | `0.40.0 → 1.1.0` |
| k3d k8s | `k3d-config.yaml` | `v1.29.15 → v1.34.x-k3s1` |

Then: `just helm-verify` + `just platform-verify`, and the Tier 1 (k3d 1.34) gate.

## Not grilled (out of EM-31 scope, deferred)

AppProject scoping · Argo webhook vs polling · `ServerSideApply` on traefik/sealed-secrets.
None block EM-31; tracked as open questions in the agent docs.
