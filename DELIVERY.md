# DELIVERY.md — EuroTransit delivery decisions

The single overview of **how EuroTransit is delivered** — every delivery/platform decision,
why it was chosen, and what it trades away. Each row points to its authoritative record: an
[ADR](docs/adr/) (immutable decision) or a [runbook](docs/delivery/) (how-to). This file is
the map; the ADRs and runbooks are the territory.

Owner: **@vojtech-n** (Delivery & Platform). Scope: cluster, GitOps, Helm, CI→registry→Git
loop, progressive delivery, platform operators, secrets. Not covered here: SLOs, consistency
model, chaos hypotheses — team-owned (see `CLAUDE.md`).

---

## The delivery loop

```
 app-repo (eurotransit-app)                    config-repo (eurotransit-config)
 ─────────────────────────                     ───────────────────────────────
 feature/EM-xx ─PR─► main                       feature/EM-xx ─PR─► main
        │  build + test                                 │
        │  push image ──► ACR (OIDC, no secret)         │
        │  bump values.yaml tag ───────────────────────►│  (GitHub App token)
                                                         ▼
                                              root-app ─► Argo CD ─► AKS cluster
                                                         (selfHeal + prune, from main)
```

CI **never** touches the cluster: it builds, pushes an immutable image, and writes a tag into
Git. Argo CD (inside the cluster) pulls and reconciles. Rollback is `git revert`, not `kubectl`.

---

## Decision index

| # | Decision | Choice | Key trade-off | Record |
|---|---|---|---|---|
| 1 | Cluster & control-plane | AKS, Free tier, Poland Central | no SLA (fine — capstone) | [ADR 0001](docs/adr/0001-aks-cluster-sizing-and-budget.md) |
| 2 | Node sizing | `3× B2s_v2` (6 vCPU / 24 GB) | CPU tight under load; fits student quota | [ADR 0005](docs/adr/0005-node-sizing-under-vcpu-quota.md) |
| 3 | Environments | one env, Azure-only (no local k3d) | no free local cluster | [ADR 0006](docs/adr/0006-drop-k3d-azure-only.md) |
| 4 | Repository model | two repos: app (code+CI) / config (state) | cross-repo write-back needed | [delivery-owner](.agent/agents/delivery-owner.md) |
| 5 | Delivery direction | pull-based GitOps; CI writes Git only | slight reconcile lag vs push | [delivery-owner](.agent/agents/delivery-owner.md) |
| 6 | Promotion model | trunk-based; one stack from `main`; no staging | no pre-prod soak | [ADR 0009](docs/adr/0009-trunk-based-single-stack.md) |
| 7 | Helm packaging | one chart for all five services | coarser default rollback | [ADR 0008](docs/adr/0008-single-helm-chart.md) |
| 8 | Argo sync policy | `selfHeal: true` + `prune: true` | drift is force-corrected | [delivery-owner](.agent/agents/delivery-owner.md) |
| 9 | Rollback | `git revert` on config-repo | never `kubectl rollout undo` | [ADR 0009](docs/adr/0009-trunk-based-single-stack.md) |
| 10 | Operator/CRD sync | `ServerSideApply` + `SkipDryRunOnMissingResource` | weaker dry-run (kubeconform compensates) | [ADR 0003](docs/adr/0003-argocd-sync-options-for-operator-crds.md) |
| 11 | Operator versions | pinned to support k8s 1.34 (Strimzi 1.1.0, CNPG 0.29.0) | manual bumps | [ADR 0004](docs/adr/0004-operator-version-pinning.md) |
| 12 | Image tagging | short Git SHA (immutable) | no semver in dev | [delivery-owner](.agent/agents/delivery-owner.md) |
| 13 | Image pull policy | `IfNotPresent` (tags immutable) | — | [vojtech](docs/agents/vojtech.md) |
| 14 | ACR push auth | GitHub OIDC → managed identity, AcrPush | one-time Owner setup | [ADR 0010](docs/adr/0010-acr-access-oidc-managed-identity.md) |
| 15 | ACR pull auth | `--attach-acr` (kubelet AcrPull) | couples to node identity | [ADR 0010](docs/adr/0010-acr-access-oidc-managed-identity.md) |
| 16 | Config-repo write-back | GitHub App installation token | more setup than a PAT | [ADR 0007](docs/adr/0007-gitops-writeback-github-app.md) |
| 17 | Graceful shutdown & probes | centralized values; liveness local-only | app must set `server.shutdown=graceful` | [ADR 0002](docs/adr/0002-graceful-shutdown-and-probes.md) |
| 18 | Ingress | Traefik only public; all services ClusterIP | single north-south entrypoint | [tls runbook](docs/delivery/tls-issuance-runbook.md) |
| 19 | TLS | cert-manager + Let's Encrypt (staging→prod) | HTTP-01 needs public LB | [tls runbook](docs/delivery/tls-issuance-runbook.md) |
| 20 | Progressive delivery | canary via `TraefikService` weights; blue/green via ingress switch | manual weight steps | [delivery-owner](.agent/agents/delivery-owner.md) |
| 21 | Kafka | Strimzi operator; topics as CRs; 1 broker (dev) | broker-quorum chaos given up | [ADR 0005](docs/adr/0005-node-sizing-under-vcpu-quota.md) |
| 22 | Secrets | Sealed Secrets, strict scope | rename breaks decryption (intended) | [delivery-owner](.agent/agents/delivery-owner.md) |
| 23 | Argo CD access | GitHub SSO (Dex) + `policy.default: role:admin` | broad RBAC (all operate) | [argocd-sso](docs/delivery/argocd-sso.md) |
| 24 | Namespace isolation | default-deny NetworkPolicy, single app ns | enforcement is CNI-dependent | [netpol checklist](docs/delivery/network-policy-checklist.md) |
| 25 | Alerting | symptom-based PrometheusRules only | no CPU/mem alerts | [vojtech](docs/agents/vojtech.md) |
| 26 | Argo blast radius | two scoped AppProjects (`platform` / `eurotransit`) | whitelists must track reality | [ADR 0011](docs/adr/0011-scoped-appprojects.md) |
| 27 | North-south routing | Traefik `IngressRoute`/`Middleware`/`TraefikService` — no native `Ingress` | Traefik-tied; k9s "Ingresses" view is empty by design | [ADR 0012](docs/adr/0012-traefik-ingressroute-over-ingress.md) |
| 28 | Config-repo CI | `validate.yml` gate on PRs + main (reuses `just helm-verify`/`helm-schema`) | must be a required check to actually block | [ADR 0013](docs/adr/0013-config-ci-validation.md) |
| 29 | Policy-as-code | kube-linter, **CI-only** (no admission controller) | 4 hardening checks excluded (deferred, tracked) | [ADR 0013](docs/adr/0013-config-ci-validation.md) |
| 30 | Secret scanning | gitleaks in CI + opt-in `.githooks` pre-commit | hooks bypassable; CI is the gate | [ADR 0013](docs/adr/0013-config-ci-validation.md) |

---

## Decisions in detail

### Cluster, cost & environment (1–3)
- **AKS Free tier, `3× B2s_v2`, Poland Central.** 3 nodes are required for chaos #3 (node
  disruption, PDBs, topology spread); 6 vCPU is the hard ceiling of the student quota, so
  sizing is a **budget, not headroom** — CPU throttles under k6 load, so read money-path p95
  with the cluster in mind (ADR 0005). Cost discipline: `az aks stop` / scale to 1 when idle.
- **Azure-only (k3d dropped).** A local cluster added a parity tax (LB, CNI, cert issuance
  differ) it could never fully pay off; offline `helm-verify`/`helm-schema` catch the
  render/CRD class of bugs instead. Trade-off: no free local cluster — on-cluster testing
  costs AKS time (ADR 0006).

### Repository & GitOps topology (4–5, 8–9, 26)
- **Two repos.** App repo owns code + CI; config repo owns desired state. CI must never hold
  cluster credentials — this split is what makes that possible (course requirement).
- **Pull-based, CI writes Git only.** Argo CD reconciles from inside the cluster. Trade-off:
  a few seconds–minutes of reconcile lag (cut with a webhook) vs a push model's cluster creds.
- **`selfHeal` + `prune` both `true`.** Git is the only source of truth; out-of-band drift is
  corrected automatically and orphaned resources are removed. Trade-off: you **cannot** hotfix
  live — a manual edit is reverted. That's intentional; rollback is `git revert` (ADR 0009).
- **Two scoped AppProjects.** `platform` (broad — installs cluster-scoped operators) and
  `eurotransit` (locked to the `eurotransit` namespace, no cluster-scoped power). Caps the
  blast radius of the app tier — the code path most likely to get a bad manifest — without
  hobbling the platform (ADR 0011).
- **Kustomize tidy of `platform/argocd/` — considered, deferred.** Folding the hand-written
  `Certificate`/`IngressRoute`/`Middleware` into a `kustomization.yaml` is cosmetic and not
  worth the risk: the `platform` app is a *directory-recurse* app, so a kustomization would
  have to be carved into its own Application (+ `directory.exclude`), and the intermediate
  `prune` could briefly drop the Argo-UI route and force a **Let's Encrypt cert re-issue**
  (against the 5/week prod limit) for zero functional gain. Left as raw manifests.

### Promotion & packaging (6–7)
- **Trunk-based, one stack.** Staging (namespace + branch) was built then dropped — not graded,
  no traffic to protect, and two stacks don't fit 6 vCPU. Safety comes from PR review +
  `helm-verify` + optional `just aks-bootstrap <branch>` on-cluster test (ADR 0009).
- **Single Helm chart.** One `values.yaml`, one Application, one place for shared config.
  Coarser default rollback, mitigated by reverting a single `image.tag` line (ADR 0008).

### Platform bootstrap (10–11)
- **`ServerSideApply`** on operators with large CRDs (cert-manager, CNPG, Strimzi,
  kube-prometheus-stack) — dodges the client-side annotation-size limit. **`SkipDryRunOnMissingResource`**
  on workloads whose CRs depend on another app's CRDs — retry instead of hard-fail. The lost
  dry-run validation is recovered by `just helm-schema` (kubeconform) in CI (ADR 0003).
- **Operator versions pinned to support k8s 1.34.** AKS is authoritative; the k3d-parity
  clause of this decision is retired by ADR 0006, but the pins (Strimzi 1.1.0, CNPG 0.29.0)
  stand (ADR 0004).

### Image build → registry → write-back (12–16)
- **Short Git SHA tags**, `IfNotPresent` pull policy — immutable, traceable, deterministic.
- **ACR push via OIDC + managed identity** (no stored password, AcrPush scoped to the
  registry); **pull via `--attach-acr`** (`imagePullSecrets: []`). Setup: `infra/acr-oidc/`
  (ADR 0010).
- **Config-repo write-back via a GitHub App** installation token — org-owned, short-lived,
  Contents:write on the config repo only. Chosen over a personal PAT (person-coupled, expiry
  babysitting). Setup: `infra/gitops-writeback-app/` (ADR 0007).

### Resilience, ingress & TLS (17–19, 27)
- **Graceful shutdown + probes centralized in `values.yaml`.** `terminationGracePeriodSeconds:
  60`, 5s `preStop`, 50s drain; liveness checks the **local process only** (never DB/Kafka) to
  avoid cascading restarts; readiness gates traffic and flips during drain (ADR 0002).
- **Traefik is the only public endpoint**; all app services are ClusterIP. **cert-manager +
  Let's Encrypt**, staging issuer first (high rate limit) then prod (trusted) — see the
  [TLS runbook](docs/delivery/tls-issuance-runbook.md).
- **Routing is Traefik `IngressRoute`, not native `Ingress`** — required for the redirect
  `Middleware` and the weighted-canary `TraefikService` (ADR 0012). Consequence: **k9s's
  Ingresses view is empty by design** — look at `kubectl get ingressroute` instead. The only
  native `Ingress` that ever appears is cert-manager's ephemeral `cm-acme-http-solver-*` during
  a cert challenge.

### Progressive delivery (20)
- **Canary** via `TraefikService` weighted routing (shift stable→canary, watch SLIs, promote
  or set canary weight to 0). **Blue/green** by switching the ingress backend, old Deployment
  kept for fast rollback. No service mesh — Traefik is already the ingress. Promotion
  thresholds are an open question with the Observability owner (proposed: error rate < 1%,
  p95 < 300ms over 5 min).

### Security, secrets & isolation (22–24)
- **Sealed Secrets, strict scope** — sealed values bound to name+namespace; rename breaks
  decryption on purpose. Controller in `sealed-secrets`. The controller's private sealing key
  is the one secret that cannot live in Git — back it up after bootstrap (`just
  seal-key-backup`) or a cluster rebuild strands every committed `SealedSecret`; see the
  [key DR runbook](docs/delivery/sealed-secrets-key-dr.md).
- **Argo CD GitHub SSO (Dex)** with `policy.default: role:admin` — broad by design (all five
  teammates operate the system; Dex gates login to the org). Scope-down path documented in the
  [SSO runbook](docs/delivery/argocd-sso.md).
- **Default-deny NetworkPolicy** for the five app pods with explicit allows (DNS, Traefik
  ingress, metrics scrape, intra-app, DB/Kafka egress). Enforcement is CNI-dependent — real on
  AKS Azure CNI/Calico. Verification checklist: [network-policy-checklist](docs/delivery/network-policy-checklist.md).

### Observability (25)
- **Symptom-based alerts only** — `CheckoutHighErrorRate`, `CheckoutHighP95Latency`,
  `InventoryServiceDown`, `KafkaConsumerLagHigh`. No CPU/memory threshold alerts (cause-based,
  noisy). SLO numbers are team-owned.

### CI validation & policy-as-code (28–30)
- **`validate.yml` is the config-repo review gate** (PRs + push to main). It reuses the local
  gates (`just helm-verify`, `just helm-schema`) so CI and local never drift, plus yamllint and
  kubeconform on the Argo manifests. Make it a **required check** on `main` for it to actually
  block (ADR 0013).
- **Policy-as-code is kube-linter, CI-only** — no in-cluster admission controller (Kyverno/
  Gatekeeper) on the 6-vCPU budget. Blocking on the checks the chart passes; 4 hardening checks
  (`run-as-non-root`, `no-read-only-root-fs`, `no-anti-affinity`, PDB eviction) are excluded as
  **deferred**, tracked in the [network-policy checklist](docs/delivery/network-policy-checklist.md).
- **Secret scanning is layered** — gitleaks in CI (enforced) + an opt-in `.githooks/pre-commit`
  (`just install-hooks`) for local fast feedback. Hooks are bypassable, so CI is the gate. Plus
  a `git ls-files` block on any unsealed `secrets/*.yaml` / `*.pem` / `*.key`.
- **ACR tag-existence** check runs under a read-only identity (`id-eurotransit-config-ci`,
  AcrPull) and soft-skips until the config-repo OIDC secrets are set (best-effort, not
  load-bearing).

---

## Runbooks (`docs/delivery/`)

| Runbook | Covers |
|---|---|
| [cluster-bootstrap.md](docs/delivery/cluster-bootstrap.md) | first-time bring-up, app-of-apps wave order, steady-state loops, manual-kubectl boundary (with control-flow diagrams) |
| [tls-issuance-runbook.md](docs/delivery/tls-issuance-runbook.md) | cert-manager HTTP-01, staging→prod promotion, verification |
| [argocd-sso.md](docs/delivery/argocd-sso.md) | Argo CD GitHub SSO (Dex) + RBAC, retiring local admin |
| [argocd-ui-access.md](docs/delivery/argocd-ui-access.md) | exposing the Argo CD UI via Traefik + TLS |
| [network-policy-checklist.md](docs/delivery/network-policy-checklist.md) | namespace hardening verification |
| [sealed-secrets-key-dr.md](docs/delivery/sealed-secrets-key-dr.md) | sealing-key backup/restore; re-seal fallback on a rebuilt cluster |

## ADRs (`docs/adr/`)

Full decision records with alternatives and consequences: [docs/adr/README.md](docs/adr/README.md).
