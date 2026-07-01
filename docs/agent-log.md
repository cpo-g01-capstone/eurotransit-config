# Agent log

Records cases where agent-produced artifacts were incorrect, unsafe, or subtly wrong.
**Minimum three entries required before the live presentation. This file is graded.**

All five team members must approve changes to this file (see CODEOWNERS).

Custodian: @marcodonatucci (Observability & Verification).

| # | Date | Area | Summary |
|---|------|------|---------|
| 1 | 2026-06-20 | CI / eurotransit-app | Wrong `paths-filter` globs for service modules |
| 2 | 2026-06-19 | GitOps / eurotransit-config | Placeholder `TODO-TEAM` repo URL in Argo CD Applications |
| 3 | 2026-06-20 | Delivery / docs vs CI | ACR documented but GHCR implemented in workflow |
| 4 | 2026-06-20 | Delivery / Justfile | `helm-dry-run` claimed no cluster needed but always contacts API server |
| 5 | 2026-07-01 | Platform / eurotransit-config | Sealed Secrets controller deployed to `kube-system`, contradicting the documented sealing namespace |
| 6 | 2026-07-01 | Platform / eurotransit-config | Strimzi operator installed with no `watchNamespaces` — would never reconcile the Kafka CR in `eurotransit` |
| 7 | 2026-07-01 | Platform / eurotransit-config | Sealed Secrets `repoURL` pointed at `bitnami-labs.github.io` (404) instead of `bitnami.github.io` |
| 8 | 2026-07-01 | Platform / eurotransit-config | k3d pinned to k8s 1.28.2 but CNPG chart 0.29.0 requires `kubeVersion >=1.29` — incompatible |
| 9 | 2026-07-01 | Delivery / Justfile | `install-cnpg` waited only for the CRD, not the controller webhook — `deploy-postgres` raced and failed |

---

## Case 1 — 2026-06-20 — CI path filters (eurotransit-app)

**What the AI produced:**
The initial `.github/workflows/ci.yml` stub used `dorny/paths-filter` globs such as
`backend/catalog/**`, `backend/orders/**`, etc., matching the *planned* layout in
`justfile` and `CODEOWNERS`, not the layout produced by the EM-13 scaffold
(`backend/catalog-service/**`, `backend/orders-service/**`, …).

**Why it was wrong:**
On a change confined to one service (e.g. only `backend/orders-service/`), the filter
would not match. The `images` job would skip that service entirely: no image rebuild,
no GitOps tag bump, and silent drift between code and cluster.

**How it was caught:**
Manual review while implementing EM-15 (Setup GitHub Actions CI), comparing the
workflow filters against `settings.gradle.kts` and the actual directory tree on `main`.

**How it was corrected:**
Updated every service filter to `backend/<service>-service/**` in
`feature/EM-15-Setup-github-actions-ci` (merged via app PR #2 / follow-up commits).

**Lesson learned:**
Before trusting AI-generated path filters, diff them against `settings.gradle.kts`
`include(...)` lines and a real `find backend -maxdepth 1 -type d`. Scaffold layout
and docs can diverge — the filesystem wins.

---

## Case 2 — 2026-06-19 — Argo CD placeholder repo URL (eurotransit-config)

**What the AI produced:**
Early bootstrap manifests `bootstrap/apps/platform.yaml` and
`bootstrap/apps/workloads.yaml` contained:

```yaml
repoURL: 'https://github.com/TODO-TEAM/eurotransit-config.git' # TO BE CHANGED
```

**Why it was wrong:**
Argo CD would fail to reconcile (or point at a non-existent org) once the app-of-apps
was applied. With `automated.selfHeal: true`, a bad source URL blocks the entire
GitOps loop — no platform components, no workloads.

**How it was caught:**
Kickoff / EM-11 review checklist before merging the platform bootstrap branch.

**How it was corrected:**
Replaced with `https://github.com/cpo-g01-capstone/eurotransit-config.git` before
merge to `main` (EM-11, config PR #6).

**Lesson learned:**
Search every generated manifest for `TODO`, `CHANGEME`, and placeholder hostnames
before the first `kubectl apply` / Argo sync. AI scaffolds often leave these behind.

---

## Case 3 — 2026-06-20 — Image registry mismatch (ACR vs GHCR)

**What the AI produced:**
Two inconsistent artifacts:
- `CLAUDE.md`, `.agent/context.md`, and `delivery-owner.md` describe **Azure Container
  Registry (ACR)** (`<acr>.azurecr.io`, `az` login, push only on `main`).
- The EM-15 CI workflow implementation uses **GHCR** (`REGISTRY: ghcr.io`,
  `docker/login-action` with `GITHUB_TOKEN`, `packages: write`).

**Why it was wrong:**
Subtly dangerous, not a compile failure: a teammate following `CLAUDE.md` would add
ACR secrets and `az acr login` steps (extra credentials, violates least-privilege),
while CI already pushes to GHCR. Conversely, Helm `values.yaml` examples still show
`*.azurecr.io` image repositories that CI will never populate.

**How it was caught:**
Cross-review during EM-15 implementation — workflow comments said GHCR but agent
context files still said ACR.

**How it was corrected:**
CI workflow committed with GHCR as the source of truth (app PR #2). **Follow-up
required:** update `CLAUDE.md`, `delivery-owner.md`, and Helm `values.yaml` image
repository fields to GHCR (or revert CI to ACR if the team chooses Azure — one
registry, documented everywhere).

**Lesson learned:**
Registry choice is a team decision, not something to split across “implementation”
and “docs”. After any AI-generated CI change, grep both repos for the old registry
string and align in the same PR.

---

## Case 4 — 2026-06-20 — `helm-dry-run` incorrectly described as cluster-free (eurotransit-config)

**What the AI produced:**
The `just helm-dry-run` recipe in the `Justfile` was initially generated with
`kubectl apply --dry-run=server -f -`, then updated to `--dry-run=client`, and finally
to `--dry-run=client --validate=false` — each iteration accompanied by a comment
claiming the recipe required no cluster. The final version read:

```just
helm-dry-run:
    @echo “Running offline dry-run (no cluster required)...”
    helm template eurotransit {{ CHART }} --namespace eurotransit \
        | kubectl apply --dry-run=client --validate=false -f -
```

**Why it was wrong:**
`kubectl apply` always performs API group discovery against the configured server
(`/api`, `/apis`) to determine resource types and namespacing — even with
`--dry-run=client` and `--validate=false`. With the kubeconfig context pointing at
an unreachable cluster (`lab02` AKS), the command fails immediately with DNS lookup
errors. The recipe was not offline despite the comment saying otherwise.

**How it was caught:**
Running `just helm-dry-run` locally with the `lab02` kubeconfig context active
(the previous course AKS cluster, no longer reachable) produced a wall of
`couldn't get current server API group list` errors and a non-zero exit code.

**How it was corrected:**
The recipe was updated to explicitly target the local k3d cluster context
(`--context k3d-eurotransit-cluster`) and to check the cluster is reachable first.
`just helm-verify` (lint + template render + secret check) is the true offline gate;
`just helm-dry-run` is documented as requiring `just up` first.

```just
helm-dry-run:
    @echo “Checking k3d cluster is reachable...”
    kubectl --context k3d-eurotransit-cluster cluster-info > /dev/null
    @echo “Running client-side dry-run against k3d...”
    helm template eurotransit {{ CHART }} --namespace eurotransit \
        | kubectl --context k3d-eurotransit-cluster apply --dry-run=client -f -
```

**Lesson learned:**
`kubectl apply --dry-run=client` is not offline — it requires API group discovery.
The only truly cluster-free validation options are `helm lint`, `helm template`, and
dedicated offline tools such as `kubeconform`. Never label a `kubectl`-based recipe
as “no cluster required”.

---

## Case 5 — 2026-07-01 — Sealed Secrets controller in the wrong namespace (eurotransit-config)

**What the AI produced:**
The platform Application `platform/sealed-secrets/sealed-secrets.yaml` set
`spec.destination.namespace: kube-system` — the upstream chart's historical default.

**Why it was wrong:**
The project's invariants (`CLAUDE.md`, `delivery-owner.md`) and the shared `just seal`
recipe all target `--controller-namespace sealed-secrets`. `kubeseal` fetches the
controller's public certificate from the namespace it is told to; with the controller
actually running in `kube-system`, every teammate's sealing command would fail to find
the controller, or (worse) seal against the wrong/absent one — silently blocking the
entire SealedSecrets workflow. Putting a third-party controller in `kube-system` also
violates least-privilege: that namespace is reserved for core cluster components.

**How it was caught:**
Delivery review while adding sync-wave annotations for EM-31 — reading the Application
alongside the Justfile revealed the controller namespace and the `kubeseal` namespace
did not match. No SealedSecrets had been committed yet, so nothing had failed loudly.

**How it was corrected:**
Changed the destination namespace to `sealed-secrets` and added
`fullnameOverride: sealed-secrets` so the controller *name* is pinned to the value the
Justfile expects rather than derived from the Helm release name. Done before the first
secret was sealed, so there was zero re-seal migration cost — the invariant's warning
("changing the namespace breaks all existing sealed manifests") only bites once secrets
exist.

**Lesson learned:**
When a controller's namespace/name is referenced from elsewhere (a Justfile, CI, docs),
those references are the contract — the deployment must match them, not the chart
default. Reconcile operator install targets against every consumer before first use,
and prefer dedicated namespaces over `kube-system` for add-on controllers.

---

## Case 6 — 2026-07-01 — Strimzi operator not watching the workload namespace (eurotransit-config)

**What the AI produced:**
`platform/strimzi/strimzi.yaml` installed the strimzi-kafka-operator chart with no
`watchNamespaces` / `watchAnyNamespace` values set, into namespace `kafka`.

**Why it was wrong:**
A Strimzi operator watches **only its own namespace** by default. The `Kafka` and
`KafkaTopic` CRs live in the `eurotransit` namespace (the bootstrap FQDN
`eurotransit-kafka-kafka-bootstrap.eurotransit.svc...` confirms it). As deployed, the
operator would install cleanly, report Healthy, and then **never reconcile the Kafka
cluster** — a silent no-op that only surfaces when a consumer fails to reach a broker
that was never created.

**How it was caught:**
Delivery review during EM-31, tracing which namespace actually holds the Kafka CRs
versus where the operator was told to watch.

**How it was corrected:**
Set `watchNamespaces: {eurotransit}` and `watchAnyNamespace: false` (least-privilege —
the chart provisions Role/RoleBinding into `eurotransit` only, not cluster-wide), and
moved the operator to `strimzi-system` per the documented invariant. A first attempt
placed the `helm:` block at `spec.helm` instead of `spec.source.helm`; Argo CD silently
ignores unknown fields, so the parameters would have had no effect. Caught by YAML
structural validation (`spec.source.helm` present, `spec.helm` nil) before commit.

**Lesson learned:**
Installing an operator is not the same as wiring it to its workloads — always confirm
the operator's watch scope covers the namespace holding its CRs. And Argo CD `Application`
overrides belong under `spec.source.helm`; a misplaced `helm:` block is accepted without
error and silently does nothing, so validate structure, not just YAML well-formedness.

---

## Case 7 — 2026-07-01 — Sealed Secrets chart repo URL 404s (eurotransit-config)

**What the AI produced:**
`platform/sealed-secrets/sealed-secrets.yaml` set
`spec.source.repoURL: https://bitnami-labs.github.io/sealed-secrets`. That host returns
`404 Not Found` for `index.yaml`; the chart is actually published at
`https://bitnami.github.io/sealed-secrets` (no `-labs`).

**Why it was wrong:**
Argo CD cannot resolve a Helm chart from a repo that 404s, so the `sealed-secrets`
Application would never sync. With no Sealed Secrets controller running, *no*
`SealedSecret` anywhere in the cluster can be decrypted — every secret-dependent
workload (DB credentials, etc.) is blocked. Because nothing had been sealed yet, the
failure was latent: the manifest looked plausible and passed YAML validation, but the
URL had never been exercised against a live cluster or `helm repo add`.

**How it was caught:**
The `just platform-verify` recipe added during EM-31 renders every pinned platform chart
straight from the manifests. It reported `FAIL sealed-secrets @ 2.15.x`, and a follow-up
`helm show chart --repo ...` returned an explicit `404 Not Found` on the `index.yaml` —
while every other github.io-hosted repo (cloudnative-pg, prometheus-community) resolved
normally, ruling out a general network problem.

**How it was corrected:**
Repo URL changed to `https://bitnami.github.io/sealed-secrets` (verified reachable), and
the pin tightened from the `2.15.x` range to the exact `2.15.4` (controller appVersion
`0.26.3`) now that the index could be queried. `just platform-verify` then passed 6/6.

**Lesson learned:**
A repo/registry URL in a manifest is only "correct" once something has actually fetched
from it — plausible-looking hostnames (`bitnami-labs` vs `bitnami`) are a classic
copy-from-memory error. Add a render-against-the-real-repo check (`helm template --repo
--version`) to CI so a dead or misspelled chart source fails a PR instead of failing an
Argo sync in the cluster.

---

## Case 8 — 2026-07-01 — Local k8s version incompatible with a pinned operator (eurotransit-config)

**What the AI produced:**
`k3d-config.yaml` pinned the local cluster to `rancher/k3s:v1.28.2-k3s1`, while
`platform/cloudnative-pg/cloudnative-pg.yaml` was pinned to CloudNativePG chart `0.29.0`.
That chart declares `kubeVersion: '>=1.29.0-0'`.

**Why it was wrong:**
The two version pins were chosen independently and are mutually incompatible. `helm
upgrade --install` refuses the chart on k8s 1.28.2 with
`chart requires kubeVersion: >=1.29.0-0 which is incompatible with Kubernetes
v1.28.2+k3s1`, so the operator can never install on the local cluster. The manifests
looked fine in isolation and passed offline render checks (`helm template` does not
enforce `kubeVersion` against a real server), so the mismatch was invisible until a live
install.

**How it was caught:**
`just bootstrap-manual` on k3d — the `install-cnpg` step failed with the kubeVersion
error. `helm show chart --version` on nearby CNPG charts confirmed the `>=1.29` floor was
introduced at 0.28.3 (0.27.0 and older have no constraint).

**How it was corrected:**
Bumped the k3d image to `rancher/k3s:v1.29.15-k3s1` — the latest 1.29 patch, which
satisfies CNPG's floor while staying inside Strimzi 0.40.0's supported ceiling (~1.29).
Chose to bump the disposable local environment rather than downgrade the operator, since
AKS (the real target) runs >=1.29 and the operator pin should match production. A comment
in `k3d-config.yaml` now records the constraint.

**Lesson learned:**
Operator chart pins carry a `kubeVersion` contract that must be validated against the
cluster's k8s version — the environment and the operator versions are one decision, not
two. Check `helm show chart <op> --version <pin> | grep kubeVersion` against the k3d/AKS
version whenever either is bumped.

---

## Case 9 — 2026-07-01 — Operator "ready" conflated with CRD established (Justfile)

**What the AI produced:**
The `install-cnpg` recipe waited only for the `Cluster` CRD to be `Established`
(`kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io`) before
returning, and `bootstrap-manual` then ran `deploy-postgres` immediately.

**Why it was wrong:**
A CRD being established does not mean the operator's controller pod is running. CNPG
registers a mutating admission webhook for `Cluster`; applying `postgres/` before the
controller has endpoints fails with `Internal error ... failed calling webhook
"mcluster.cnpg.io" ... no endpoints available for service "cnpg-webhook-service"`. The
recipe's ordering assumed CRD readiness implied controller readiness.

**How it was caught:**
`just bootstrap-manual` on k3d — `deploy-postgres` failed on the webhook call while the
controller was still starting.

**How it was corrected:**
`install-cnpg` now polls `cnpg-webhook-service` for populated endpoints (up to ~3 min)
before returning, so the admission webhook is guaranteed live before any `Cluster` is
created.

**Lesson learned:**
"Operator installed" has three distinct milestones — CRDs established, controller Ready,
and (if it uses one) admission webhook endpoints available. Any manifest applied through
a webhook must wait for the last of these, not the first. Prefer waiting on the concrete
downstream condition (webhook endpoints / controller Available) over the CRD alone.
