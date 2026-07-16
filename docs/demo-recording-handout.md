# EuroTransit — 5-Minute Demo Recording Handout

Step-by-step runbook for recording the capstone demo video (DoD deliverable:
"5-min recorded demo"). Follow it top to bottom; every command is copy-pasteable.

**What the 5 minutes must prove (Pillar D):**
1. GitOps loop — Git is the source of truth, Argo CD reconciles
2. Canary rollout with an SLI-based promote/abort decision
3. Blue/green cutover with instant rollback
4. A symptom-based alert firing under an injected failure, watched on the dashboards

**Recording strategy: four segments, recorded separately, concatenated.**
Real-time constraints make a single take impractical: the alert needs its 1-minute
`for:` window, the canary gate is defined over 5 sustained minutes, and Argo CD
polls every ~3 minutes. Each segment below is self-contained; cut them together
in order. (QuickTime or OBS; 1920×1080; terminal font ≥ 18 pt; hide bookmarks bar.)

---

## Constraints that shape the script

- **`main` is PR-protected.** Every `values.yaml` change on camera is a
  *pre-opened, pre-approved PR* merged live with `gh pr merge` — nothing is
  pushed directly. This is a feature: the video shows the real process.
- **CPU budget (ADR 0005/0027):** the canary track and the green track each cost
  a full pod. Never run both demos' extra tracks simultaneously — the script
  sequences them so one is torn down before the next starts.
- **Argo CD polling lag (~3 min):** after each merge, force a refresh on camera:
  ```bash
  kubectl -n argocd annotate application eurotransit \
    argocd.argoproj.io/refresh=normal --overwrite
  ```
- **CE-6 (variant B, pod-failure) self-expires after 2 minutes** — the
  alert-firing segment is recorded inside that window; the timeline below is
  anchored to the injection time (T0). (Switched from CE-1 after a live dry-run
  on 2026-07-16 showed `PaymentsHighP95Latency` does not reliably fire: the
  Orders breaker fast-fails almost every call, so only sparse half-open probes
  reach Payments — too thin to hold p95 over its `rate()` window for the full
  `for: 3m`. `PaymentsServiceDown` is a plain `absent()` check instead —
  deterministic, independent of load shape. Validated live: pending at T0+31s,
  firing at T0+1:34.)

---

## Pre-flight (T minus 45 min — nothing here is recorded)

### 1. Cluster health

```bash
kubectl get application -n argocd eurotransit        # Synced / Healthy
kubectl get pods -n eurotransit                       # all Running, no restarts
just chaos-status                                     # no active experiments
just chaos-enable                                     # one-time Chaos Mesh grant (idempotent)
```

### 2. Port-forwards (three separate terminals, leave running)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
```

### 3. Browser tabs, in this order (you will cycle through them left to right)

1. Argo CD UI — `eurotransit` application tree
2. Grafana — **EuroTransit — RED (money path)**, time range "Last 15 minutes", auto-refresh 10s
3. Prometheus — `http://localhost:9090/alerts`
4. Alertmanager — `http://localhost:9093`
5. GitHub — the pre-opened PRs (step 5)

### 4. Baseline load (app repo, leave running for the whole session)

```bash
# Duration must cover all recording, incl. retakes
BASE_URL=https://eurotransit.vojtechn.dev VUS=3 DURATION=60m k6 run tests/k6/baseline.js
```

Verify on the RED dashboard: request rate flat, errors ~0%, p95 well under 500 ms.
**This is your steady state — screenshot it for the chaos writeup.**

### 5. Pre-open and pre-approve the PRs (a teammate approves, you merge on camera)

| PR | Change in `values.yaml` | Merged |
|----|--------------------------|--------|
| **PR-1 "canary: enable orders canary at 10%"** | `orders.canary.enabled: true`, `orders.canary.tag: "<candidate SHA>"`, `orders.canary.weight: 10` | on camera (Segment 2) |
| **PR-2 "canary: abort — weight to 0, disable"** | `orders.canary.enabled: false`, `weight: 0`, `tag: ""` | on camera (Segment 2) *or* after recording |
| **PR-3 "bluegreen: deploy catalog green track"** | `catalog.blueGreen.enabled: true`, `catalog.blueGreen.tag: "<candidate SHA>"` | **before** Segment 3 (green must already be Ready) |
| **PR-4 "bluegreen: switch active track to green"** | `catalog.blueGreen.activeTrack: "green"` | on camera (Segment 3) |

Candidate SHA: use the current image tag of a known-good build (the demo shows
the *mechanics and the gate*; the candidate does not need new behaviour).
PR bodies use `.github/PULL_REQUEST_TEMPLATE.local.md` as always.

> **Sequencing:** merge PR-2 (canary teardown) before merging PR-3 (green track
> up) — the budget fits one extra pod, not two.

### 6. Dry-run each segment once without recording

Especially Segment 4 — know exactly what the pending→firing transition looks like.
(Segment 4 was already dry-run live on 2026-07-16 against CE-6 variant B: pending
at T0+31s, firing at T0+1:34, recovered ~T0+2:48 — timings above reflect that run.
Still worth one more dry-run on the day, load and cluster state can shift.)

---

## Segment 1 — GitOps steady state (target length 0:40)

**Screen: Argo CD tab → terminal → Grafana tab.**

| Step | Do | Say (one line) |
|---|---|---|
| 1 | Argo CD UI: application tree, **Synced / Healthy** badges | "Five services, delivered by Argo CD from the config repo — Git is the only way anything reaches this cluster." |
| 2 | `git log -5 --format='%h %an — %s' -- deploy/charts/eurotransit/values.yaml` — point at the `eurotransit-gitops-writeback[bot]` author lines | "CI ships images by committing a tag bump; Argo reconciles. No CI credentials ever touch the cluster." |
| 3 | Grafana RED dashboard: flat rate, ~0% errors, low p95 under k6 load | "Steady state under baseline load — this is what every later claim is measured against." |

---

## Segment 2 — Canary on Orders (target length 1:30)

**Pre-condition:** PR-1 open + approved; blue/green NOT enabled.

| Step | Do | Say |
|---|---|---|
| 1 | `gh pr merge <PR-1> --squash` then force Argo refresh (command above) | "Enabling a 10% canary is one merged commit." |
| 2 | `kubectl get pods -n eurotransit -l 'app.kubernetes.io/name in (eurotransit-orders,eurotransit-orders-canary)' -w` — canary pod appears and goes Ready (the canary carries its own `name` label; the stable-only selector would miss it) | "Traefik's weighted service now splits /api/orders 90/10." |
| 3 | Show `deploy/charts/eurotransit/templates/traefik-services.yaml` weights briefly, or the TraefikService in the Argo tree | — |
| 4 | Grafana RED: the per-service Rate / Errors / Duration panels group `by (job)` — a new **eurotransit-orders-canary** series appears (dedicated ServiceMonitor; allow ~30 s for the first 15 s-interval scrapes) | "The canary is scraped separately — the gate reads the canary's own SLIs, not the blend. Team-ratified: error rate < 1% AND p95 < 300 ms sustained 5 minutes — stricter than the SLO on purpose." |
| 5 | `gh pr merge <PR-2> --squash` + Argo refresh; canary pod terminates | "Abort is symmetric: weight to zero, one commit. Promote would instead bump `orders.image.tag` to the candidate." |

> Narration honesty: you are demonstrating the *mechanism and the gate*, then
> aborting without waiting the full 5-minute window — say so. Cutting the wait
> is fine; claiming you waited is not.

---

## Segment 3 — Blue/green on Catalog (target length 1:00)

**Pre-condition:** PR-3 merged ≥ 5 min ago (green pod Ready, receiving no traffic);
PR-4 open + approved.

| Step | Do | Say |
|---|---|---|
| 1 | `kubectl get pods -n eurotransit -l app.kubernetes.io/name=eurotransit-catalog` — both tracks running | "Green is fully deployed and warmed, serving nothing." |
| 2 | In a spare terminal start: `while true; do curl -s https://eurotransit.vojtechn.dev/api/catalog -o /dev/null -w "%{http_code} %{time_total}s\n"; sleep 0.5; done` | "Continuous requests against catalog — watch for any gap." |
| 3 | `gh pr merge <PR-4> --squash` + Argo refresh | "The switch is one field: `activeTrack: green`. The IngressRoute repoints; Traefik cutover is instant." |
| 4 | Curl loop: no non-200, no latency spike; `kubectl logs` on the green pod shows requests arriving | "Zero-downtime cutover." |
| 5 | Show (don't run) the rollback: `git revert <switch-commit>` → PR → Argo | "Blue never stopped running — rollback is reverting one commit. Ratified policy: delete the old track after 5 clean minutes." |

---

## Segment 4 — Alert firing under injected failure (target length ~1:00 on camera)

This segment is **anchored to the injection time (T0)** because
`PaymentsServiceDown` has `for: 1m` and CE-6 (variant B, pod-failure) holds the
outage for a fixed 2-minute window.

> **Why CE-6 instead of CE-1 here:** `PaymentsHighP95Latency` needs enough slow
> samples inside its `rate()` window while the breaker is open. Live-tested
> 2026-07-16: the breaker fast-fails almost every call, so only sparse
> half-open probes (one burst of 5 every `waitDurationInOpenState: 30s`) reach
> Payments — too thin to hold p95 above threshold continuously for `for: 3m`;
> the alert never left `inactive` across a full 5-minute CE-1 window.
> `PaymentsServiceDown` is a plain `absent(up{...}==1)` check instead —
> deterministic, independent of load shape or breaker timing.

**Timeline (wall clock):**

| Time | Action (off camera unless noted) |
|---|---|
| T0 | `just chaos ce-6-pod-failure-payments` — both Payments pods unresponsive (pause image), fixed 2-min window |
| T0+0:30 | Prometheus `/alerts`: `PaymentsServiceDown` flips to **pending** — confirm, don't record yet |
| **T0+1:00** | **START RECORDING** on the Prometheus alerts tab |
| ~T0+1:35 | Alert transitions **pending → firing** on camera |
| T0+2:00 | Stop recording |
| T0+2:00–3:00 | Chaos expires; pods replaced; verify recovery (below) |

**On camera (T0+1:00 → T0+2:00):**

| Step | Do | Say |
|---|---|---|
| 1 | Prometheus `/alerts`: alert **pending**, show its expression (`absent(up{job="eurotransit-payments"}==1)`, `for: 1m`) | "We just killed Payments entirely with Chaos Mesh — both replicas, not one. The alert is symptom-based: the scrape target is gone, not a CPU threshold." |
| 2 | Grafana RED: **Payments circuit breaker — state** panel shows the breaker OPEN per orders pod, opened on connection failures (not slow calls, unlike CE-1) | "Orders' circuit breaker opened on failure rate — every authorize call gets a hard connection error." |
| 3 | Grafana: catalog Rate/Errors panels still flat | "Browsing is untouched — the failure is bulkheaded to the money path's payment leg." |
| 4 | Alert flips to **firing** → switch to Alertmanager tab: alert grouped/routed | "After the full 1-minute `for:` window it pages. Pending-then-firing is deliberate — no flapping pages." |

**Recovery check (off camera, but capture a screenshot for the writeup):**

```bash
just chaos-status                       # experiment finished
# Prometheus /alerts: alert back to inactive within ~1 min of pod recovery
# Payments pods: READY again; breaker CLOSED
```

Note: the Payments HPA may transiently scale 2→4 on the CPU burst from the
pod-failure restart — self-corrects within a few minutes, no action needed. If
Segment 2/3 (canary/blue-green) records *after* this segment, wait for Payments
to settle back to 2 replicas first (CPU budget, ADR 0005/0027).

---

## Segment 5 — Wrap (target length 0:20)

**Screen: Argo CD tab, everything Synced / Healthy again.**

> "Everything you saw — the canary, the cutover, the recovery — is in Git
> history. Rollback anywhere is `git revert`; Argo CD self-heals the rest.
> Agent-generated manifests went through the same PR gate, and the ones that
> were wrong are in `docs/agent-log.md`."

---

## Contingencies

| Symptom | Cause / fix |
|---|---|
| Canary or green pod stuck `Pending` | CPU quota — confirm the *other* demo's extra track is torn down (PR-2 merged before PR-3) |
| Alert never leaves *inactive* after injection | Check both Payments pods actually went `0/1` Ready (`kubectl get pods -n eurotransit -l app.kubernetes.io/name=eurotransit-payments`) — if not, the pod-failure patch didn't apply; re-run `just chaos ce-6-pod-failure-payments` |
| Alert still *pending* past T0+1:30 | Should not happen (`for: 1m`, validated live 2026-07-16 — firing at T0+1:34) — check Prometheus scrape config for drift |
| Argo stays `OutOfSync` after refresh | Check the app-repo CI bot didn't race a tag bump into `values.yaml`; re-refresh |
| Cutover shows errors in the curl loop | Green wasn't Ready — always merge PR-3 well before Segment 3 and check readiness first |
| Payments HPA still at 4 replicas before Segment 2/3 | Expected after Segment 4 (CPU burst from the pod-failure restart) — wait a few minutes for it to settle back to 2 before starting the next segment's extra track (CPU budget, ADR 0005/0027) |

---

## After recording

1. Concatenate segments in order; confirm total ≤ 5:00.
2. Merge any demo PRs left open (or close them) — leave `main` with
   `canary.enabled: false`, `blueGreen.enabled: false`.
3. Verify end state: `kubectl get application -n argocd eurotransit` → Synced / Healthy.
4. File the steady-state and recovery screenshots with the chaos experiment docs.
5. Tick the DoD items demonstrated (canary, blue/green, symptom alert) in
   `docs/capstone-dod.md`.
