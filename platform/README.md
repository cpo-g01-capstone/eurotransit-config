# Platform

This directory contains Argo CD `Application` manifests for cluster-wide infrastructure.
Each file here is a child app of the `platform` app-of-apps (`bootstrap/apps/platform.yaml`),
so adding a new component is just adding one `Application` manifest in this directory.

Planned / in-progress components:
- Traefik (Ingress)
- cert-manager
- CloudNativePG
- Strimzi (Kafka)
- kube-prometheus-stack ✅ (`kube-prometheus-stack.yaml`)
- Chaos Mesh
- Sealed Secrets ✅ (`sealed-secrets.yaml`)

## Monitoring — kube-prometheus-stack

`kube-prometheus-stack.yaml` deploys the Prometheus Operator, Prometheus, Alertmanager,
Grafana, kube-state-metrics, and node-exporter via the upstream
`prometheus-community/kube-prometheus-stack` Helm chart (pinned to `86.2.3`).

- **Namespace:** `monitoring` (auto-created by Argo CD)
- **Release name:** `kube-prometheus-stack` — kept fixed so service `ServiceMonitor`s
  labelled `release: kube-prometheus-stack` (see `CLAUDE.md`) are selected.
- **Cross-namespace discovery:** `*SelectorNilUsesHelmValues: false` so Prometheus
  scrapes any `ServiceMonitor`/`PodMonitor` and loads any `PrometheusRule`/`Probe` in the
  cluster (e.g. the per-service ones shipped from the application chart in `eurotransit`).
- **Sync:** `ServerSideApply=true` is required — the Operator CRDs exceed the client-side
  `last-applied-configuration` annotation size limit.
- **Storage:** ephemeral (emptyDir) for dev/k3d. Add a `storageSpec` PVC before any
  environment that must retain metric history across restarts.
- **Grafana access (dev):** `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`
  (default credentials `admin` / `prom-operator`). Replace with a SealedSecret before any
  shared cluster — never commit a plaintext password.
