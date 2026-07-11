# Agent log

Records cases where agent-produced artifacts were incorrect, unsafe, or subtly wrong.
**Minimum three entries required before the live presentation. This file is graded.**

Reviewed like any PR (single approval — ADR 0019); substantive changes should still be discussed by the whole team.

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
| 10 | 2026-07-01 | Platform / eurotransit-config | ClusterIssuer `sync-wave` assumed to gate on a CRD installed by a *different* Argo app — `SyncFailed` |
| 11 | 2026-07-08 | Async / eurotransit-config context docs | Notifications consumed-topics inconsistency (`order-confirmed` vs `notification-requested`) |
| 12 | 2026-07-08 | Async / eurotransit-app notifications | AI-designed `suspend` @KafkaListener silently swallowed handler exceptions (no retry/DLT) |
| 13 | 2026-07-11 | Delivery / eurotransit-config | Orders chart injected `SPRING_DATASOURCE_*`, but the app reads `ORDERS_DB_*` — env ignored, app fell back to `localhost:5432` and crashlooped |
| 14 | 2026-07-11 | GitOps / eurotransit-config | chaos-mesh Application under `project: platform` sourced an external chart repo not in the AppProject's `sourceRepos` — Argo `InvalidSpecError` |
| 15 | 2026-07-12 | Async / eurotransit-app orders | Agent's rebase conflict resolution silently reverted the D4 `order-failed` publish (took `--theirs` = its own stale commit) |

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

---

## Case 10 — 2026-07-01 — sync-wave cannot gate a CRD owned by a different Argo app (eurotransit-config)

**What the AI produced:**
`platform/cert-manager/clusterissuer-{staging,prod}.yaml` were given
`argocd.argoproj.io/sync-wave: "1"` on the assumption that this guarantees the
cert-manager operator (wave 0) — and therefore its CRDs — are installed before the
`ClusterIssuer` resources are applied.

**Why it was wrong:**
The ClusterIssuers live in the `platform` app-of-apps, but the `cert-manager.io` CRDs are
installed by the **separate `cert-manager` Argo Application** the platform app *creates*.
A `sync-wave` only orders resources **within a single Application's own sync** — it cannot
wait for a *different* Application to finish reconciling. So the `platform` sync tried to
apply the ClusterIssuers before `cert-manager.io/ClusterIssuer` was registered, and Argo
CD reported `SyncFailed / Missing`: "The Kubernetes API could not find
cert-manager.io/ClusterIssuer ... Make sure the CRD is installed on the destination
cluster." Sync-waves gate on *this app's* resource health (including child Application
health), but not deterministically on a grandchild's side effect (CRD registration).

**How it was caught:**
Watching the `platform` Application sync in the Argo CD UI during the EM-31 branch test on
k3d — both ClusterIssuers showed `SyncFailed / Missing`.

**How it was corrected:**
Added `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` to both
ClusterIssuers so the sync retries (eventual consistency) instead of hard-failing until the
CRD exists. The cleaner-but-heavier alternative — moving the ClusterIssuers into their own
Application ordered strictly after `cert-manager` at the app-of-apps level — was noted for
later if determinism is preferred over eventual consistency.

**Lesson learned:**
`sync-wave` orders resources inside one Application; it does not synchronize across
Applications. When a resource depends on a CRD that a *different* app installs, don't rely
on wave ordering alone — use `SkipDryRunOnMissingResource=true` (+ retry), or make the
dependency explicit with a separate, later-ordered Application.

---

## Case 13 — 2026-07-11 — DB env var names in the chart didn't match the app's contract (eurotransit-config)

**What the AI produced:**
`deploy/charts/eurotransit/templates/orders/deployment.yaml` wired the database connection
using Spring's conventional relaxed-binding names:

```yaml
- name: SPRING_DATASOURCE_URL
  value: "jdbc:postgresql://eurotransit-orders-db-rw...:5432/ordersdb"
- name: SPRING_DATASOURCE_USERNAME   # secretKeyRef → eurotransit-orders-db-app
- name: SPRING_DATASOURCE_PASSWORD
```

The manifest *looked* correct in isolation — a valid JDBC URL to the CloudNativePG `-rw`
service, credentials pulled from the operator secret via `secretKeyRef`, no plaintext.

**Why it was wrong:**
`orders-service/src/main/resources/application.yml` does **not** read `spring.datasource.*`.
It uses **R2DBC** at runtime and a **separate JDBC URL for Flyway** (Flyway is JDBC-only),
both behind **service-prefixed** placeholders with `localhost` defaults:

```yaml
spring.r2dbc.url:  ${ORDERS_DB_R2DBC_URL:r2dbc:postgresql://localhost:5432/ordersdb}
spring.flyway.url: ${ORDERS_DB_JDBC_URL:jdbc:postgresql://localhost:5432/ordersdb}
```

Because the chart set `SPRING_DATASOURCE_*` and the app never reads those keys, the injected
values were silently ignored and the app fell back to its `localhost:5432` default. Flyway
then failed with `Connection to localhost:5432 refused` and the pod crashlooped — while the
Deployment, Service, and secret all *appeared* healthy and correctly wired. Argo CD showed
`Synced` (the manifests matched Git) but `Degraded` (pods never went Ready), which is easy to
misread as a cluster problem rather than a config-contract mismatch. The same root cause
affects Notifications; Inventory has the reactive deps but no datasource config written yet.

**How it was caught:**
Investigating three crashlooping services (orders, inventory, notifications) on the AKS
cluster. Pod logs showed `localhost:5432` despite the pod env clearly containing the correct
`SPRING_DATASOURCE_URL`. Cross-referencing the app repo's `application.yml` revealed the env
var names the code actually binds — `ORDERS_DB_*`, not `SPRING_DATASOURCE_*`.

**How it was corrected:**
Renamed the env block in `orders/deployment.yaml` to the app's contract —
`ORDERS_DB_R2DBC_URL`, `ORDERS_DB_JDBC_URL`, `ORDERS_DB_USERNAME`, `ORDERS_DB_PASSWORD` —
with the R2DBC and JDBC URLs both built from `.Values.orders.db.{host,port,name}` and
credentials still via `secretKeyRef` on `eurotransit-orders-db-app`. Documented the DB
env-var contract in `CLAUDE.md` (Architecture constraints + naming table) and
`docs/agents/vojtech.md` so future chart edits don't reintroduce `SPRING_DATASOURCE_*`.

**Lesson learned:**
A manifest that is internally valid can still be wrong — the env var **names** are an API
contract owned by the application, not by Spring convention. When wiring config into a
service, verify the keys against the consuming code's `application.yml`, not against what the
framework *usually* calls them. `Synced + Degraded` with a `localhost` fallback in the logs
is the signature of injected config the app never reads.
## Case 11 — 2026-07-08 — Notifications consumed-topics inconsistency (eurotransit-config context docs)

> **Draft — pending team approval.** This entry was drafted by the agent while
> implementing the Notifications consumer. Per CODEOWNERS all five members must approve
> before it merges to `main`.

**What the AI produced:**
Two agent-generated context docs disagree on which topics the Notifications service consumes:
- `.agent/context/money-path.md` (step 7): Notifications consumes **`order-confirmed`** only.
- `.agent/context/kafka-topics.md`: lists Notifications as consumer of **both**
  `order-confirmed` **and** `notification-requested` (the latter with producer `Orders`).

No service actually produces `notification-requested` — no Orders code emits it, and the
money path never references it.

**Why it was wrong:**
Subtly wrong, not a compile failure. Taken literally, an implementer wiring Notifications
from `kafka-topics.md` would add a **second `@KafkaListener` on a topic that has no
producer** — a listener that never fires — or the team would create a `KafkaTopic` CR
(`notification-requested`) that is **orphaned**: declared infrastructure, never written,
never read. It also misleads the reader into thinking Orders must perform a dual-write
(`order-confirmed` **and** `notification-requested`) after confirmation, which — without a
transactional outbox — is itself a consistency hazard.

**How it was caught:**
Cross-checking `kafka-topics.md` against `money-path.md` while designing the Notifications
consumer (ADR-001, eurotransit-app), before writing the listener.

**How it was corrected:**
Resolved by **ADR-001** (eurotransit-app `docs/adr/`): Notifications consumes
`order-confirmed` only, consistent with the money path and with the team's
consistency-over-availability preference. **Follow-up required in this repo:** remove
`notification-requested` from `.agent/context/kafka-topics.md` and from any `KafkaTopic`
CRs, **or** annotate it explicitly as "reserved, not yet wired". Team decision + PR.

**Lesson learned:**
Event topology must be reconciled across `money-path.md` and `kafka-topics.md` in the same
change. A topic row with a producer/consumer that no code implements is a latent trap —
grep for every topic name across both repos and confirm a real producer *and* consumer
exist before declaring the CR.

---

## Case 12 — 2026-07-08 — `suspend` @KafkaListener silently swallowed exceptions (eurotransit-app)

> **Draft — pending team approval** (CODEOWNERS). Caught while implementing the Notifications
> consumer (ADR-001..004).

**What the AI produced:**
The AI-authored design (ADR-004 / the notifications spec) and the first implementation used a
Kotlin `suspend` @KafkaListener:

```kotlin
@KafkaListener(topics = ["order-confirmed"], containerFactory = "kafkaListenerContainerFactory")
suspend fun onOrderConfirmed(event: OrderConfirmedEvent) { service.handle(event) }
```

It compiled, and the **happy path passed** — messages were consumed and marked `SENT`.

**Why it was wrong (subtly):**
With this Spring Kafka version, a `suspend` @KafkaListener **does not propagate handler
exceptions to the container's `DefaultErrorHandler`**. When the send failed, the exception was
swallowed: **no bounded retry, no publish to `order-confirmed.DLT`, and the offset was still
committed** (`AckMode.RECORD`) — the failed notification was silently lost. The integration test
proved it: the recoverer ran **0** times and only **1** delivery attempt occurred. This defeats
the entire resilience design (ADR-003): "no lost notifications, poison messages parked in the
DLT". A green happy-path test hid a broken failure path — exactly the kind of gap the money path
must not have.

**How it was caught:**
The DLT integration test (`OrderConfirmedDltIT`) asserted that an always-failing send lands in
`order-confirmed.DLT` and the row becomes `FAILED`. It timed out; debug logging showed the
recoverer never fired and there were no retries.

**How it was corrected:**
Switched to a non-`suspend` handler that bridges to the suspending service with `runBlocking`,
taking the raw `ConsumerRecord` (Spring Kafka's typed-payload conversion returned `KafkaNull` for
an already-deserialized value on a non-suspend method):

```kotlin
@KafkaListener(topics = ["order-confirmed"], containerFactory = "kafkaListenerContainerFactory")
fun onOrderConfirmed(record: ConsumerRecord<String, OrderConfirmedEvent?>) {
    val event = record.value() ?: return
    runBlocking { service.handle(event) }
}
```

The exception now surfaces synchronously → `DefaultErrorHandler` retries → DLT + `FAILED`.
**Team decision required:** this uses `runBlocking`, which `CLAUDE.md` bans "outside bootstrap".
The consumer thread is a dedicated blocking poll loop (not a reactive context), so blocking here
is arguably correct, but the team must ratify the exception to the rule (or choose an alternative
bridge) and update ADR-004 / the spec accordingly.

**Lesson learned:**
A passing happy-path test is not evidence the failure path works — for money-path handlers,
always test the failure/DLT/redelivery paths explicitly. Framework "it compiles and consumes"
does not imply "errors are handled"; verify exception propagation end-to-end.

---

## Case 14 — 2026-07-11 — chaos-mesh Application's chart repo not allowed by its AppProject (eurotransit-config)

**What the AI produced:**
The Chaos Mesh installation (ADR 0017, PR #31) declared the Argo CD Application under
`project: platform`, sourcing the chart from `https://charts.chaos-mesh.org`.

**Why it was wrong:**
Argo CD validates an Application's `source.repoURL` against its AppProject's
`sourceRepos`. The `platform` project (ADR 0011) allowed **only the config repo**, so the
Application was rejected at sync time with
`InvalidSpecError: application repo https://charts.chaos-mesh.org is not permitted in project 'platform'`.
The other six operators never hit this because they run under `project: default`, whose
`sourceRepos` is `*`. The agent adopted the platform-scoping intent without validating the
project's source constraints against an external chart source — the scoping model
constrains *sources*, not just destinations and resource kinds.

**How it was caught:**
At sync, by the delivery owner: the Application stuck `Unknown/InvalidSpecError` while the
other operators synced fine. He diagnosed the mismatch and proposed two options
(extend `platform.sourceRepos` vs fall back to `project: default`).

**How it was corrected:**
Option A — the pinned chart repo added to the platform project's `sourceRepos`
(`bootstrap/apps/projects.yaml`), keeping ADR 0017's deliberate platform-scoping intact;
the now-inaccurate "Both restrict sourceRepos to the config repo" comment updated; the
ADR 0017 consequence corrected (it wrongly claimed the required change was a CRD-group
allowance).

**Lesson learned:**
When an agent assigns an Application to a scoped AppProject, it must check the project's
`sourceRepos` (and destinations) against the Application's actual source. "More scoped"
projects fail closed: an external Helm repo needs an explicit, pinned entry.

---

## Case 15 — 2026-07-12 — Rebase conflict resolution silently reverted the D4 compensation publish (eurotransit-app)

**What the AI produced:**
While rebasing the catalog PR (#17) onto a main that had just received #16 (D4:
seat-release compensation via `order-failed`), the agent hit a conflict on
`KafkaErrorHandlingConfig.kt` — its own commit only renamed an ADR reference in a
comment. It resolved with `git checkout --theirs <file>`, believing it was taking
main's version.

**Why it was wrong (subtly):**
During a **rebase**, `--theirs` refers to the commit being replayed — the agent's own
**stale, pre-#16** copy — not the new base. The resolution therefore compiled cleanly,
passed CI, and silently deleted #16's behaviour: the recoverer stopped publishing
`order-failed` on redelivery exhaustion, while Inventory's `OrderFailedConsumer`
(also from #16) stayed deployed and listening. The D4 compensation loop was broken
with zero test failures — orders would be marked FAILED but seats never released.

**How it was caught:**
By @marcodonatucci, reviewing main's behaviour after the merge: the just-merged D4
feature no longer existed on main. Restored in #18.

**How it was corrected:**
#18 re-applies the `order-failed` publish in the recoverer (idempotent on the
Inventory side, so replayed exhaustions are safe).

**Lesson learned:**
Two lessons. (1) Git semantics: in a rebase, ours/theirs INVERT with respect to a
merge — `--theirs` is the branch's own commit. (2) Deeper: a conflict resolution is a
**semantic** decision, not a textual one; after resolving, diff the resolved file
against BOTH parents and ask "whose behaviour did I keep, and is any recently-merged
feature missing?". "It compiles and CI is green" does not prove the merge preserved
intent — CI has no test for a feature whose call site was just deleted.
