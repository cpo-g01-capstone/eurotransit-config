# Platform

Argo CD `Application` manifests for cluster-wide infrastructure operators.
Each subdirectory is one platform component; `bootstrap/apps/platform.yaml` discovers
them all via `directory.recurse: true`.

To add a new component: create a new subdirectory and drop an `Application` manifest in it.
Argo CD will pick it up on the next sync without touching any other file.

## Components

| Directory | Component | Namespace | Status |
|---|---|---|---|
| `traefik/` | Traefik ingress controller | `traefik` | ✅ |
| `cert-manager/` | TLS certificate automation | `cert-manager` | ✅ |
| `cloudnative-pg/` | PostgreSQL operator | `cnpg-system` | ✅ |
| `strimzi/` | Kafka operator | `strimzi-system` | ✅ |
| `monitoring/` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) | `monitoring` | ✅ |
| `sealed-secrets/` | Sealed Secrets controller | `kube-system` | ✅ |
| `chaos-mesh/` | Chaos engineering controller | `chaos-testing` | ⬜ not yet added |

## Notes

- All operator Applications are pinned to explicit chart versions (never `HEAD`):
  cert-manager `v1.20.3`, traefik `41.0.1`, cloudnative-pg `0.29.0`,
  strimzi `0.40.0`, kube-prometheus-stack `86.2.3`. Bump deliberately in a PR.
  The `bootstrap/*` app-of-apps Applications correctly stay on git `HEAD` (they
  track `main`, which is how CI tag bumps reach the cluster).
- `strimzi/strimzi.yaml` is pinned to `0.40.0` to match `just install-operator`.
  ⚠️ Unresolved: the Justfile installs it into `eurotransit` while this Application
  targets `strimzi-system` — the team must pick a single install path.
- `sealed-secrets/sealed-secrets.yaml` uses `targetRevision: 2.15.x` (minor pinned,
  patch floats). Pin the exact `2.15.z` before the AKS deployment.
- Grafana default credentials (`admin` / `prom-operator`) are fine for local k3d.
  Replace with a SealedSecret before any shared cluster.

Orders DB cluster CR lives in `postgres/` — synced by `apps/data-infrastructure.yaml`,
not by this platform app-of-apps.

## Monitoring — kube-prometheus-stack

`monitoring/kube-prometheus-stack.yaml` deploys Prometheus Operator, Prometheus,
Alertmanager, Grafana, kube-state-metrics, and node-exporter.

- **Release name:** `kube-prometheus-stack` — fixed so per-service `ServiceMonitor`s
  labelled `release: kube-prometheus-stack` are selected automatically.
- **Cross-namespace discovery:** `*SelectorNilUsesHelmValues: false` — Prometheus scrapes
  any `ServiceMonitor`/`PodMonitor` and loads any `PrometheusRule` in the cluster.
- **Sync:** `ServerSideApply=true` required — Operator CRDs exceed the client-side
  annotation size limit.
- **Storage:** ephemeral (`emptyDir`) for dev/k3d. Add a `storageSpec` PVC with the
  `managed-csi` storage class before deploying to AKS.
- **Grafana access (dev):**
  `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`
