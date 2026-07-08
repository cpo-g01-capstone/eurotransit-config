# Staging environment (one cluster, two tracks)

How EuroTransit runs a **staging** stack alongside **prod** on the *same* AKS
cluster, so changes can be validated before they reach `main`. This is standard
GitOps multi-env: a second Argo CD Application, its own namespace, tracking a
different Git branch. Platform operators are cluster-wide and **shared**.

```
root-app (main)
  ├─ eurotransit          main    → ns eurotransit          → eurotransit.vojtechn.dev
  └─ eurotransit-staging  staging → ns eurotransit-staging  → staging.eurotransit.vojtechn.dev
```

- **Prod**: `apps/eurotransit.yaml`, tracks `main`, ns `eurotransit`.
- **Stage**: `apps/eurotransit-staging.yaml`, tracks the long-lived `staging`
  branch, ns `eurotransit-staging`, overlay `values-staging.yaml` (host + 1 replica).
- Both Application *manifests* live in `apps/` on `main`, so `root-app` manages
  both. Only the *source branch* differs.

## What is and isn't in staging

- **In:** the five-service app chart — Deployments, Services, IngressRoute +
  redirect Middleware, Certificate, ServiceMonitors, PDBs, HPA, NetworkPolicy.
- **Shared (not duplicated):** Traefik, cert-manager, Strimzi, CloudNativePG,
  kube-prometheus-stack, sealed-secrets — one install per cluster.
- **Out (by decision):** Kafka and Postgres. The app chart doesn't deploy those
  (they're separate `apps/kafka.yaml` / `apps/data-infrastructure.yaml`, prod-ns
  only). Services that need Kafka/DB will be **NotReady** in staging — expected,
  and fine for testing ingress, TLS, routing, and progressive delivery. Add a
  stage Kafka/PG later if a test needs the full money path (requires widening
  Strimzi `watchNamespaces` to include `eurotransit-staging`).

## The workflow

**Test a change:**
```bash
git switch staging
git merge --no-ff feature/EM-XX-my-change    # or cherry-pick
git push origin staging
# Argo CD reconciles eurotransit-staging within ~seconds (webhook) / ~3 min (poll).
# Watch: kubectl -n argocd get application eurotransit-staging
#        kubectl -n eurotransit-staging get pods,ingressroute,certificate
# Verify: https://staging.eurotransit.vojtechn.dev/...
```

**Promote to prod:** open a PR `staging → main`, review, merge. `root-app` picks
up whatever changed; the `eurotransit` (prod) App reconciles from `main`.

**Rule:** never edit `main` to change what's in staging, and never hand-edit the
cluster — push to the `staging` branch and let Argo converge (self-heal is on).

## DNS & TLS

- **DNS:** one wildcard record `*.eurotransit.vojtechn.dev → <Traefik LB IP>`
  covers `staging.` (this) and `argocd.` (Argo CD UI) in a single entry. The prod
  apex `eurotransit.vojtechn.dev` has its own record.
- **TLS:** staging inherits `certIssuer: letsencrypt-staging` from
  `values-azure.yaml` — **untrusted** certs (browser warning) but high rate
  limits, so you can re-issue freely while iterating. Prod uses `letsencrypt-prod`.
  Each host gets its own HTTP-01 cert; no wildcard cert needed.

## First-time setup (once)

1. Land `apps/eurotransit-staging.yaml` + `deploy/charts/eurotransit/values-staging.yaml`
   on `main` (via the EM-37 PR).
2. Create the long-lived branch from main: `git switch -c staging main && git push -u origin staging`.
3. After the AKS bootstrap, `root-app` creates the `eurotransit-staging`
   Application automatically; Argo creates the namespace and syncs.

## Known limitations

- **Images:** staging pulls the same ACR images as prod. Until the ACR push +
  pull-auth task lands, staging pods `ImagePullBackOff` (ingress/TLS still testable).
- **Observability overlap:** stage ServiceMonitors are scraped by the same
  Prometheus; filter by `namespace="eurotransit-staging"` in queries/dashboards.
- **Budget:** two stacks on a 3-node pool is tight (ADR 0001). Staging runs 1
  replica/service and no Kafka/PG to stay light; scale down or `az aks scale` up
  if the pool gets full.
