# Namespace Hardening — Team Verification Checklist

Tracks namespace-level isolation controls for the `eurotransit` namespace. Items
are **proposed by the delivery owner (@vojtech-n)** and must be **verified with the
team** before the demo. Nothing here changes a design decision the team owns
(SLOs, consistency model, etc.) — these are operational hardening controls.

Status legend: ⬜ not started · 🟡 implemented, not verified · ✅ verified by team

---

## 1. NetworkPolicy (implemented — needs enforcement verification)

**What shipped:** `deploy/charts/eurotransit/templates/shared/networkpolicy.yaml`,
gated by `networkPolicy.enabled` (default `true`). Default-deny for the five app
pods (`app.kubernetes.io/part-of: eurotransit`) plus explicit allows:

| Policy | Direction | Allows |
|---|---|---|
| `eurotransit-default-deny` | ingress + egress | nothing (baseline) |
| `eurotransit-allow-dns` | egress | CoreDNS in `kube-system` (UDP/TCP 53) |
| `eurotransit-allow-ingress-traefik` | ingress | from `traefik` ns → app port 8080 |
| `eurotransit-allow-metrics-scrape` | ingress | from `monitoring` ns → app port 8080 |
| `eurotransit-allow-intra-app` | ingress + egress | app-pod ↔ app-pod on 8080 |
| `eurotransit-allow-egress-data` | egress | app pods → in-namespace 5432 (CNPG) + 9092 (Kafka) |

**Operator-managed pods (CNPG Postgres, Strimzi Kafka) are deliberately NOT
selected** — their operators manage their own NetworkPolicies; applying our
default-deny to them risks breaking replication / leader election.

To verify with the team:

- [ ] 🟡 **CNI enforcement.** NetworkPolicy is only enforced by a CNI that
      supports it — a CNI without support treats these as a no-op. Confirm the
      target cluster (AKS Azure CNI / Calico) actually enforces them.
- [ ] Namespace label `kubernetes.io/metadata.name` exists on `kube-system`,
      `traefik`, `monitoring` (auto-applied by k8s ≥1.21 — confirm on the target).
- [ ] Positive test: checkout money path still works with policies applied
      (Traefik → Orders → Inventory/Payments → DB/Kafka).
- [ ] Negative test: a pod in a foreign namespace **cannot** reach
      `eurotransit-orders:80` (proves default-deny is enforced).
- [ ] Negative test: app pod cannot open arbitrary egress (e.g. to the internet)
      unless explicitly allowed.
- [ ] **External egress decision (team-owned):** does Payments call an external
      provider? If so add an explicit allow-egress policy — default-deny blocks it.
      *Currently no external egress is permitted.*
- [ ] Confirm app port (`8080`), DB port (`5432`), Kafka port (`9092`) in
      `values.yaml > networkPolicy` match the actual service definitions.

---

## 2. ResourceQuota + LimitRange (not started)

- [ ] ⬜ `ResourceQuota` on `eurotransit` to cap aggregate CPU/memory/pod count
      (blast-radius cap). Team to agree the numbers.
- [ ] ⬜ `LimitRange` with default requests/limits so a container missing
      `resources:` can't starve the node. Complements `helm lint --strict`.
- [ ] Decide owner: chart template vs. one-time bootstrap manifest. (If in the
      chart, it lands in the Argo-created namespace automatically.)

## 3. Pod Security Admission labels (not started)

- [ ] ⬜ Add PSA labels to the `eurotransit` namespace via Argo CD
      `managedNamespaceMetadata` (the namespace is Argo-created via
      `CreateNamespace=true`, so a `kind: Namespace` in the chart would conflict):

      ```yaml
      # apps/eurotransit.yaml under spec.syncPolicy
      managedNamespaceMetadata:
        labels:
          pod-security.kubernetes.io/enforce: restricted
          app.kubernetes.io/part-of: eurotransit
      ```
- [ ] Verify the five Spring Boot pods satisfy `restricted` (non-root,
      seccompProfile, no privilege escalation) — may need `securityContext` edits.
      Start with `warn`/`audit` before `enforce`.

## 4. Namespace ownership model (confirmed — record for the team)

- [x] All five services live in a single `eurotransit` namespace (consistent with
      the single-chart decision). Per-service namespaces rejected — isolation is
      provided by NetworkPolicy, not namespace boundaries.
- [x] Platform operators each in their own namespace (`argocd`, `cert-manager`,
      `cnpg-system`, `strimzi-system`, `sealed-secrets`, `monitoring`,
      `chaos-testing`).
- [x] Namespace created and named by Argo CD (`destination.namespace` +
      `CreateNamespace=true`); chart templates use `{{ .Release.Namespace }}`,
      never a literal.

---

*Gate before opening PRs that touch these: `just helm-verify`.*
