# Progressive delivery runbook — Orders canary & Catalog blue/green

*Companion to ADR 0026. Every step is a Git commit on this repo — Argo CD
does the applying. Keep the RED dashboard and the burn-rate alerts open throughout;
drive steady traffic with `just load-baseline` (or the k6 E2E script) so the SLIs
have signal.*

---

## A. Canary rollout on Orders

**Gate (team-ratified, ADR 0026):** canary error rate < 1% AND p95 < 300 ms, sustained 5 minutes,
measured on the canary's own metrics (dedicated ServiceMonitor). No burn-rate
alert may fire during the window.

### 1. Start the canary
One commit in `deploy/charts/eurotransit/values.yaml`:
```yaml
orders:
  canary:
    enabled: true
    weight: 10          # 10% of /api/orders traffic
    tag: "<candidate-sha>"
```
Argo deploys `eurotransit-orders-canary` (1 pod) and the weighted TraefikService
splits 90/10. Verify:
```bash
kubectl get pods -n eurotransit -l app.kubernetes.io/track=canary
kubectl get traefikservice eurotransit-orders-weighted -n eurotransit -o yaml | grep -A2 weight
```

### 2. Watch the gate (5 minutes)
Canary-only SLIs (Grafana Explore or the RED dashboard filtered by service):
```promql
# error rate (canary pods only)
sum(rate(http_server_requests_seconds_count{namespace="eurotransit", service="eurotransit-orders-canary", status=~"5.."}[2m]))
/ sum(rate(http_server_requests_seconds_count{namespace="eurotransit", service="eurotransit-orders-canary"}[2m]))

# p95 (canary pods only)
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="eurotransit", service="eurotransit-orders-canary", uri!~"/actuator.*"}[5m])))
```
Also confirm the canary pod took Kafka partitions (it must prove the async
stages too): consumer-group panel, or `kubectl logs <canary-pod> | grep partitions`.

### 3a. Promote (gate held)
One commit:
```yaml
orders:
  image:
    tag: "<candidate-sha>"   # stable becomes the candidate
  canary:
    enabled: false           # canary track torn down, weight collapses to 100
```

### 3b. Abort (gate failed)
One commit — or `git revert` of step 1:
```yaml
orders:
  canary:
    enabled: false
```
Traffic is 100% stable within one reconcile. Record WHY in the rollout notes
(the failed gate reading is the interesting artifact — screenshot it).

---

## B. Blue/green switch on Catalog

**Window (team-ratified, ADR 0026):** after the switch, the old track stays up for 5 clean minutes
(instant rollback path), then is cleaned up.

### 1. Stand up green
```yaml
catalog:
  blueGreen:
    enabled: true
    activeTrack: "blue"      # traffic still on blue
    tag: "<candidate-sha>"
```
Green (2 pods) starts, warms its AP cache from Kafka (broadcast consumer replays
`inventory-reserved` from earliest), gets scraped by its own ServiceMonitor.
Validate it WITHOUT traffic: pods Ready, no restarts, cache-size/lag panels sane.

### 2. Switch
```yaml
catalog:
  blueGreen:
    activeTrack: "green"
```
The IngressRoute now serves `eurotransit-catalog-green`. Cutover is atomic at
Traefik. Verify from outside:
```bash
curl -s https://<host>/api/catalog | head -c 200   # 200, data served by green
kubectl get ingressroute eurotransit -n eurotransit -o yaml | grep -B1 -A2 catalog
```

### 3a. Rollback (anything degrades within the window)
`git revert` the switch commit → `activeTrack: "blue"` → instant cutback. Blue
never stopped running; zero recovery time beyond the reconcile.

### 3b. Cleanup (5 clean minutes — the ratified window, ADR 0026)
One commit that makes green's version the new blue and tears green down:
```yaml
catalog:
  image:
    tag: "<candidate-sha>"   # blue now runs the promoted version
  blueGreen:
    enabled: false
    activeTrack: "blue"
```
(The blue Deployment rolls to the promoted tag — a routine rolling update on a
service that is out of the traffic-decision path; see the DORA section of
ADR 0026 for why this is fine here and not on /api/orders.)

---

## Demo tips (recorded demo / live presentation)

- Split screen: Grafana RED dashboard + terminal running the k6 baseline.
- Narrate the Git side: every phase transition is a commit in this repo — show
  `git log --oneline` alongside the dashboards ("GitOps means the rollout has a
  reviewable history; rollback is `git revert`").
- For the canary demo, an artificial "bad candidate" makes the abort path
  visible: deploy a canary tag with a known slow endpoint, watch the gate fail,
  abort, show traffic back at 100% stable — that IS the value of the pattern.
