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

- `monitoring/kube-prometheus-stack.yaml` is pinned to chart version `86.2.3`.
  Bump deliberately; never float to `HEAD`.
- `strimzi/strimzi.yaml` uses `targetRevision: HEAD` — should be pinned to `0.40.0`
  to match `just install-operator`.
- `sealed-secrets/sealed-secrets.yaml` uses `targetRevision: 2.15.x` — pin to a full
  version before the AKS deployment.
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
