# Ubiquitous Language

Canonical terminology for the **EuroTransit** capstone. Extracted from the project
reference (`CLAUDE.md`, delivery-owner and Vojtech agent files). Use these terms
exactly in code, manifests, commits, docs, and discussion.

## Marketplace & services

| Term              | Definition                                                                 | Aliases to avoid                       |
| ----------------- | -------------------------------------------------------------------------- | -------------------------------------- |
| **EuroTransit**   | The multi-service train-ticket marketplace being built and operated        | the app, the platform, the system      |
| **Catalog**       | Service that lists products/offers; read-heavy and tolerant of staleness   | products, listings service             |
| **Orders**        | Service that orchestrates the purchase workflow                            | order service, checkout service        |
| **Inventory**     | Service that tracks finite seats; the contended resource                   | seats, stock service                   |
| **Payments**      | Service that authorizes payment under strict idempotency                   | billing, payment service               |
| **Notifications** | Fully async service that sends confirmations; must degrade gracefully      | notifier, email service                |
| **Money path**    | The critical request flow: gateway → Orders → Inventory/Payments → Kafka → Notifications | critical path, happy path, checkout flow |

## Order lifecycle & async pipeline

| Term                | Definition                                                                       | Aliases to avoid              |
| ------------------- | -------------------------------------------------------------------------------- | ----------------------------- |
| **Checkout**        | A customer's end-to-end attempt to purchase, spanning the money path             | purchase, transaction         |
| **Reservation**     | Inventory's atomic hold on a finite seat for an order                            | booking, lock, allocation     |
| **Idempotency key** | Composite key (order ID + event type) that dedupes redelivered work              | dedupe key, request ID        |
| **Oversell**        | Reserving more seats than exist — the failure Inventory must prevent             | overbooking                   |
| **Double-charge**   | Authorizing the same payment twice — the failure Payments must prevent           | double-billing                |
| **Graceful degradation** | Checkout still succeeds when Notifications is fully down                     | fallback, failover            |
| **Event**           | A domain fact published to Kafka; each event name is also its topic name         | message, record               |

The five events / topics: `order-placed`, `inventory-reserved`, `payment-authorized`,
`order-confirmed`, `notification-requested`.

## GitOps delivery

| Term                       | Definition                                                                          | Aliases to avoid                        |
| -------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------- |
| **Configuration repository** | Repo holding desired state only (Helm chart, platform manifests, docs)            | config-repo, gitops dir, the manifests  |
| **Application repository**   | Repo holding source code, tests, and CI                                           | app-repo, the code                      |
| **Delivery loop**          | CI bumps image tag in config-repo → Argo CD reconciles → cluster converges           | pipeline, deploy flow                   |
| **Argo CD Application**    | The `Application` CR named `eurotransit` that reconciles the chart                   | the app (ambiguous), the deployment     |
| **Synced**                 | Live cluster state matches the Helm-rendered manifests from `main`                   | deployed, up-to-date                    |
| **Healthy**                | All Deployments meet min replicas; pods pass readiness; DB and Kafka are `Ready`     | working, green, running                 |
| **Rollback**               | `git revert` of the offending config-repo commit — never `kubectl rollout undo`      | rollout undo, redeploy                  |
| **Tag bump**               | CI commit setting `<service>.image.tag` to the short Git SHA in `values.yaml`        | version bump, image update              |
| **SealedSecret**           | Encrypted secret safe to commit; the only secret form allowed in Git                 | secret, sealed secret (as `kind: Secret`) |

## Progressive delivery

| Term              | Definition                                                                       | Aliases to avoid            |
| ----------------- | -------------------------------------------------------------------------------- | --------------------------- |
| **Canary**        | Routing a traffic fraction to a new version via `TraefikService` weights         | A/B, gradual rollout        |
| **Blue/Green**    | Standing up the new version alongside the old, then switching the Ingress backend | red/black, swap             |
| **Stable track**  | The current-version Service in a weighted `TraefikService` (starts at weight 100) | primary, prod track         |
| **Canary track**  | The new-version Service in a weighted `TraefikService` (starts at weight 0)       | test track, next            |
| **Promote**       | Shift all traffic to the new version and retire the old track                     | cut over, finalize          |
| **Abort**         | Set canary weight to 0, returning all traffic to stable                           | cancel, rollback (reserve for Git revert) |

## Resilience & pod lifecycle

| Term                       | Definition                                                                        | Aliases to avoid             |
| -------------------------- | --------------------------------------------------------------------------------- | ---------------------------- |
| **Liveness probe**         | Checks only local process health; must never touch a downstream dependency        | health check (ambiguous)     |
| **Readiness probe**        | Checks local readiness including Kafka + DB connectivity; gates traffic            | health check (ambiguous)     |
| **Drain**                  | Refusing new traffic while in-flight work finishes on SIGTERM                      | shutdown, teardown           |
| **PodDisruptionBudget**    | Guarantee of minimum available replicas during voluntary disruption               | PDB budget (redundant)       |
| **Circuit breaker**        | Guard on a synchronous cross-service call (e.g. Orders → Payments)                 | breaker, fuse                |
| **Bulkhead**               | Isolated resource pool so one flow's saturation can't starve another              | pool, partition              |
| **Backpressure**           | Load shedding under overload, surfaced as HTTP 429                                 | throttling, rate limit       |

## Observability

| Term                  | Definition                                                                     | Aliases to avoid              |
| --------------------- | ------------------------------------------------------------------------------ | ----------------------------- |
| **SLI**               | A measured indicator (error rate, p95 latency, availability)                   | metric (too broad)            |
| **SLO**               | A target on an SLI; a team-owned decision, never agent-invented                | goal, threshold               |
| **Error budget**      | Allowed SLO violation, consumed per chaos experiment                           | budget (ambiguous)            |
| **Symptom-based alert** | Alert on user-visible impact (error rate, latency, target down)              | cause-based alert, CPU alert  |
| **ServiceMonitor**    | CR telling Prometheus how to scrape a service's `/actuator/prometheus`         | scrape config                 |
| **PrometheusRule**    | CR declaring alerting rules as Kubernetes resources                            | alert config                  |

## Chaos engineering

| Term             | Definition                                                                        | Aliases to avoid          |
| ---------------- | --------------------------------------------------------------------------------- | ------------------------- |
| **Steady state** | The measured normal behaviour, defined from SLIs before an experiment             | baseline, normal          |
| **Hypothesis**   | The team's stated prediction of system behaviour under a failure; team-owned      | guess, assumption         |
| **Failover**     | CloudNativePG promoting a replica to primary after the primary is lost            | switchover, HA            |
| **RTO**          | Recovery Time Objective — stated recovery window a chaos report validates         | recovery time (loose)     |

## Relationships

- A **Checkout** traverses the **money path** and produces one **order-placed** **Event**.
- One **order-placed** **Event** must yield exactly one **Reservation** (idempotency prevents **oversell**).
- **Payments** authorizes at most once per **Checkout**, keyed by an **Idempotency key** (prevents **double-charge**).
- **Notifications** consumes `notification-requested` but its failure never fails a **Checkout** (**graceful degradation**).
- CI commits a **Tag bump** to the **Configuration repository**; the **Argo CD Application** then makes the cluster **Synced**.
- A **Rollback** is a `git revert` on the **Configuration repository** — because `selfHeal` treats an out-of-band change as drift.
- An **Argo CD Application** can be **Synced** yet not **Healthy** (e.g. bad tag → CrashLoopBackOff).
- A **Canary** splits traffic between a **stable track** and a **canary track**; the outcome is **promote** or **abort**.

## Example dialogue

> **Delivery owner:** "CI just pushed a **tag bump** to the **configuration repository**. Is the **Argo CD Application** **Synced** yet?"

> **Observability owner:** "**Synced**, but not **Healthy** — the new **Orders** image is CrashLooping. Do we **abort** the **canary**?"

> **Delivery owner:** "There's no **canary** on this one, it went straight to the **stable track**. So this is a **rollback**: I'll `git revert` the **tag bump**, not touch `kubectl` — `selfHeal` would just re-apply the bad state otherwise."

> **Observability owner:** "Good. And the **liveness probe** on **Orders** only checks the local process, right? If it checked the **DB** we'd get cascading restarts on top of this."

> **Delivery owner:** "Correct — **liveness** is local-only. **Readiness** is what checks Kafka and DB, and it **drains** in-flight work on SIGTERM. A CrashLoop here is the image, not a **failover**."

## Flagged ambiguities

- **"the app" / "Application"** was overloaded three ways: the **Argo CD Application** CR, the **Application repository** (source code), and a running service. Reserve "**Argo CD Application**" for the CR, "**Application repository**" for the source repo, and name the specific service (e.g. "**Orders**") otherwise.
- **"critical path" vs "money path"** were used interchangeably. Canonical term is **money path**.
- **"health check"** is ambiguous between **liveness** (local only) and **readiness** (includes DB/Kafka). Always say which — conflating them is the project's flagship agent mistake.
- **"rollback"** was used for both a Git revert and a canary abort. Reserve **rollback** for the `git revert` delivery action; use **abort** for pulling canary traffic to 0.
- **"Synced" vs "Healthy"** are distinct and must not be merged — a service can be **Synced** but **Unhealthy**. Never report "it's deployed" without saying which.
- **"config-repo" / "gitops dir" / "the manifests"** all name the **Configuration repository**. CI clones it into a local `gitops/` directory, which is the source of the "gitops dir" alias — avoid it in prose.
