# CE-5 — CloudNativePG primary failover (Orders database)

*Capstone chaos experiment #5. No Chaos Mesh CR needed: the injection is killing the current
primary pod of `eurotransit-orders-db` and observing the operator promote the standby.
Prerequisites: the ADR 0021 topology reconciled (`instances: 2`, synchronous replication) and the
`kubectl cnpg` plugin installed (`brew install kubectl-cnpg` or krew).*

## Scope (made explicit after the team's adversarial audit)

This experiment covers **`eurotransit-orders-db` only** — the money-path writer and the one
database with an HA topology (2 instances, sync replication — ADR 0021). Inventory, payments
and notifications DBs deliberately run 1 instance (cluster CPU budget, ADR 0001; ADR 0021 records the
trade-off): killing their primary means downtime-until-restart, not failover, and that is
**out of scope by declared design**, not an oversight. If the budget discussion reopens,
inventory-db is the next candidate for 2 instances.

## Declared objectives (stated BEFORE the run — ADR 0021)

- **RTO = 60 s**: from primary kill to checkout writes succeeding again.
- **RPO = 0** (single-failure scenario): synchronous replication acks a commit only once the
  standby has it — no acknowledged order may be missing after promotion. *(Bound: does not cover
  the double failure standby-then-primary; `dataDurability: preferred` degrades to async if the
  standby is down — in that state, abort the run.)*

## Hypothesis

Killing the primary Postgres pod will NOT lose any acknowledged order and checkout write
availability is restored within 60 s:

1. the CNPG operator detects the failure and **promotes the standby** automatically (no manual
   `promote` needed for a failover — we only *observe*);
2. the `-rw` service repoints to the new primary; the Orders service reconnects (R2DBC pool);
3. every order acked before the kill is present after promotion (**RPO = 0**);
4. writes fail or block for < 60 s (**RTO**), and the sync entry returns clean errors (not
   hangs) during the gap;
5. the killed pod comes back as a standby and re-attaches (cluster back to 2 healthy instances).

## Steady state

- Checkout SLIs within SLO; `kubectl cnpg status eurotransit-orders-db -n eurotransit` shows
  1 primary + 1 standby, replication **streaming (sync)**, lag ≈ 0.
- Record the current primary: `kubectl get cluster eurotransit-orders-db -n eurotransit -o jsonpath='{.status.currentPrimary}'`.

## Method

1. Record steady state. Note the orders count and max order ID:
   ```sql
   SELECT count(*), max(id) FROM orders;   -- via psql on the -rw service
   ```
2. Start continuous checkout load (curl/k6) that **logs each acked order ID with a timestamp** —
   this log is the RPO evidence.
3. Inject — **force-delete** the current primary pod (with a watch on promotion in a second terminal):
   ```bash
   PRIMARY=$(kubectl get cluster eurotransit-orders-db -n eurotransit -o jsonpath='{.status.currentPrimary}')
   date -u +%T.%3N              # T0 — injection timestamp
   kubectl delete pod "$PRIMARY" -n eurotransit --grace-period=0 --force --wait=false
   kubectl cnpg status eurotransit-orders-db -n eurotransit --verbose   # repeat / watch
   ```
   > ⚠️ **`--grace-period=0 --force` is load-bearing** (Run 1 finding): a plain graceful delete
   > sends SIGTERM and CNPG enters *smart shutdown* (`smartShutdownTimeout: 180 s`) — established
   > connections (the Orders R2DBC pool!) keep writing through the "deleted" primary for up to
   > 3 minutes, so you measure a controlled switchover, not a crash. SIGKILL is also what a Chaos
   > Mesh `pod-kill` delivers. And take RTO from the **ack log**, not from
   > `status.currentPrimary` — the status field lags the data plane by seconds.
4. Measure **RTO**: T1 = timestamp of the first acked checkout after T0 (from the load log).
   RTO = T1 − T0. Also note when `status.currentPrimary` flipped.
5. Verify **RPO = 0**: after promotion, for every order ID the load harness logged as acked
   before T0, confirm the row exists:
   ```sql
   SELECT count(*) FROM orders WHERE id = ANY (:acked_ids);  -- must equal the acked count
   ```
   Cross-check dedup/idempotency tables the same way as the CE-2 pre-test (I1/I2/I3).
6. Recovery: wait for the deleted pod to return and re-attach as standby; confirm
   `kubectl cnpg status` shows sync streaming again. Steady state restored.

## What to observe

- **Promotion timeline** in operator events: `kubectl get events -n eurotransit --field-selector involvedObject.name=eurotransit-orders-db --sort-by=.lastTimestamp`.
- **Checkout SLIs during the gap** (RED dashboard): error/latency blip bounded to the RTO window;
  5xx during the gap are expected and budgeted — note how much error budget the run consumed.
- **Application reconnect behaviour**: does the R2DBC pool recover on its own, or only after
  readiness flaps? (Feeds the resilience story, not just the DB one.)
- **USE dashboard**: restarts/ready-replicas on orders-db pods.

## Pass / fail

- **PASS**: RTO ≤ 60 s, zero acked orders missing (RPO = 0), killed pod rejoins as standby, no
  manual intervention needed.
- **FAIL**: any acked order missing after promotion; write outage > 60 s; cluster stuck with a
  single instance; manual surgery required to converge.

## Results

Full execution record: [`ce-5-cnpg-failover-run-1.md`](ce-5-cnpg-failover-run-1.md).

| Date | Operator | Primary killed | T0 (kill) | Primary flipped at | T1 (first acked write) | RTO | Acked orders checked | Missing | Budget consumed | Outcome |
|------|----------|----------------|-----------|--------------------|------------------------|-----|----------------------|---------|-----------------|---------|
| 2026-07-12 | @marcodonatucci (+Claude) | `-db-1`, **graceful delete** (method bug) | 14:19:01Z | T0+184.8 s (status) | outage only T0+182.7→185.8 s (3.17 s) | n/a — wrong scenario, see run doc | 2 635 | **0** | 3 × 5xx | **FINDING** → method corrected |
| 2026-07-12 | @marcodonatucci (+Claude) | `-db-2`, **SIGKILL** | 14:29:35Z | T0+21.4 s (status; data plane ≈ +17 s) | **T0+17.3 s** | **17.3 s** | 916 | **0** | 25 bad req ≈ 0.07 % time-budget | **PASS** |
| 2026-07-13 | @vojtech-n (reviewer) | `-db-2`, **SIGKILL**, pristine seed | 20:14:59Z | T0+19.9 s (status; data ≈ +16.8 s) | **T0+16.76 s** | **16.8 s** | 435 pre-T0 (1021 whole-run) | **0** | 19 bad req / 12.4 s outage | **PASS — reviewer reproduction** ([run 3](ce-5-cnpg-failover-run-3.md)) |

## Conclusion

> **Draft — pending team ratification (ADR 0019 / agentic policy: conclusions are team-owned).**

- **Hypothesis held (Run 2):** RTO 17.3 s ≤ 60 s, RPO = 0 (0/916 acked lost; all later CONFIRMED),
  killed pod rejoined as standby at +52.9 s, zero manual intervention, and every error in the gap
  was a clean sub-second 5xx — no hangs, no thread exhaustion (breaker/bulkhead never involved:
  this is the *DB* path failing fast). Orders pods: 0 restarts, no readiness flap — the R2DBC pool
  recovered on its own; the RTO is promotion-dominated, not app-reconnect-dominated, so no app-side
  fix is indicated.
- **RTO split (as the template asks):** detection+promotion ≈ 17 s, app reconnect ≈ 0 s (first
  post-promotion request succeeded), status-field lag ≈ 4 s (excluded — cosmetic).
- **The Run 1 finding is the operational lesson:** graceful deletes exercise the *maintenance*
  path (3.17 s blip after a 180 s smart-shutdown window — excellent for planned node drains,
  directly relevant to CE-3), while only SIGKILL exercises *failure*. Our runbooks now say which
  is which.
- **Sync-replication overhead:** none observable at this traffic — checkout p95 during steady
  state matched the pre-CE-5 baseline (~300 ms client-side p95 vs ~240 ms p50; same harness pre/post).
- **Follow-ups fed elsewhere:** DB pod anti-affinity observation (primary+standby on one node) →
  ADR 0023 / CE-3; catalog AP-cache reseed divergence → known ADR 0006 property, no action.
