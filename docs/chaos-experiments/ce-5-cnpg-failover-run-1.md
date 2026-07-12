# CE-5 / Runs 1–2 — CloudNativePG primary failover (2026-07-12, ~16:19 CEST)

*Execution record for [`ce-5-cnpg-failover.md`](ce-5-cnpg-failover.md). **Run 1 accidentally
measured the wrong scenario** — a graceful deletion, not a crash — and that finding is the most
valuable output of the session: it changed the method (Run 2 uses SIGKILL) and taught us how CNPG
actually behaves on the two paths. Kept in full, per the scientific method: observe honestly,
conclude, correct, re-run.*

## Setup (both runs)

| | |
|---|---|
| Date / operator | 2026-07-12 / @marcodonatucci (Claude driving harness + kubectl, per session authorization; ADR 0019 gate on this record) |
| Target | `eurotransit-orders-db` (2 instances, quorum sync `any 1`, `dataDurability: preferred` — ADR 0021) |
| Load / RPO evidence | curl harness, 3 workers ≈ 5 orders/s through the public gateway; **every acked (202) orderId logged with a ms timestamp** — the ack log IS the RPO proof |
| Steady state before Run 1 | cnpg status: healthy, streaming quorum, lag ≈ 0.1 ms; checkout 202s at p50 ≈ 240 ms client-side (TLS from outside), 0 errors; demo route reseeded to 5 000 seats |
| DB baseline | 9 544 orders before Run 1 |

**Pre-run observations (recorded before injecting):**
- Both DB instances sat on the **same node** (`aks-sysb2s-…00000p`) — irrelevant for pod-kill,
  but it means CE-3's node-drain would take out primary AND standby together. Fed to ADR 0023.
- Catalog's AP cache showed 0 seats while inventory had 741 — expected `AP / tolerant-of-staleness`
  divergence after manual reseeds (app ADR 0006): the cache follows `inventory-reserved` events and
  cannot see DB-level reseeds. Orders are unaffected (reservation is CP in Inventory).

---

## Run 1 — `kubectl delete pod` (graceful): the wrong experiment, the best finding

**T0 = 14:19:01.3Z.** Expected: prompt failover. Observed instead:

| t (rel) | event |
|---|---|
| +1.3 s | cluster `ready 1/2`, phase **"Failing over"**; operator event `FailingOver` at +6 s |
| +0 … +182 s | **checkout writes NEVER stop** — 202s keep flowing at steady rate, p95 flat (303 ms vs 342 ms baseline) |
| +182.7 … +185.8 s | the only outage: **3.17 s ack gap**, 3 × HTTP 500 (clean, ~0.32 s each — no hangs) |
| +184.8 s | `status.currentPrimary` flips to `-db-2` |
| +256.5 s | killed pod back as standby, cluster **2/2 healthy** |

- Traffic: 2 638 requests → 2 635 acked, 3 × 500.
- **RPO: 0 missing of 2 635 acked; all 2 635 later CONFIRMED** (the full pipeline absorbed it, not
  just the DRAFT write).

**Finding (method bug): a graceful pod delete is a *controlled shutdown*, not a crash.**
`kubectl delete pod` sends SIGTERM; the CNPG instance manager enters *smart shutdown* with
`spec.smartShutdownTimeout` = **180 s** (our default): new connections are refused, but
**established sessions keep working** — and Orders' R2DBC pool held established connections, so
checkout kept writing through a "deleted" primary for three minutes. The real stop + promotion only
happened when the smart window expired (the 3.17 s gap at +183 s). Two consequences:

1. Run 1 does **not** test the hypothesis (primary *failure*); it accidentally proved the
   *maintenance/switchover* path is near-zero-impact (a great property, just a different claim).
2. `status.currentPrimary` **lags** the actual data-plane transition — timing must come from the
   ack log (as the runbook's RTO definition already says), not from the CR status.

**Method correction:** the crash scenario requires `--grace-period=0 --force` (SIGKILL), which is
also what a Chaos Mesh `pod-kill` sends. Main doc updated.

---

## Run 2 — SIGKILL (`--grace-period=0 --force`): the real failover

**T0 = 14:29:35.6Z**, primary `-db-2` (the Run-1 survivor).

| t (rel) | event |
|---|---|
| −0.6 s | last ack from the old primary era |
| +0.6 s | last in-flight 202; **write outage begins** |
| +3.0 s | cluster `ready 1/2`, phase "Failing over" |
| **+17.3 s** | **first acked write on the new primary** → write outage = **16.65 s** |
| +21.4 s | `status.currentPrimary` flips to `-db-1` (status lag ≈ 4 s behind the data plane) |
| +52.9 s | killed pod rejoined as standby, **2/2 healthy**, streaming quorum, timeline 3 |

- Traffic: 941 requests → 916 acked, **20 × HTTP 500 + 5 client timeouts**, all inside
  T0+1 … +20 s; every 500 returned in ~0.3 s — **clean refusals, zero hangs** (the sync entry's
  bounded behaviour the hypothesis demanded).
- Latency (acked only): pre p95 441 ms → first 30 s p95 1 085 ms (max 4.7 s) → post p95 434 ms.
- **RPO: 0 missing of 916 acked; all 916 later CONFIRMED.** Sync replication (`quorum any 1`) held:
  nothing acked was lost across the promotion.
- Orders pods: **0 restarts, no readiness flap** — the R2DBC pool re-resolved the `-rw` service and
  recovered on its own within the outage window.
- Error budget: ~17 s of write unavailability ≈ **0.07 %** of the 30-day time budget
  (432 min); request-based, 25 bad / 941 in the window.

## Verdict vs pass criteria (Run 2 = the hypothesis test)

| Criterion | Declared | Measured | |
|---|---|---|---|
| RTO (kill → writes succeed) | ≤ 60 s | **17.3 s** | ✅ |
| RPO (acked orders lost) | 0 | **0 / 916** (and 0 / 2 635 in Run 1) | ✅ |
| Clean errors, no unbounded hangs | required | all 5xx ≤ 0.33 s | ✅ |
| Killed pod rejoins as standby | required | +52.9 s, quorum streaming | ✅ |
| Manual intervention | none | none | ✅ |

**PASS.** Full session evidence (ack CSVs, timelines, cnpg snapshots) archived by the operator.
