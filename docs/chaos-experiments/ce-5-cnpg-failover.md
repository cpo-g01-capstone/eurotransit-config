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
3. Inject — delete the current primary pod (with a watch on promotion in a second terminal):
   ```bash
   PRIMARY=$(kubectl get cluster eurotransit-orders-db -n eurotransit -o jsonpath='{.status.currentPrimary}')
   date -u +%T.%3N              # T0 — injection timestamp
   kubectl delete pod "$PRIMARY" -n eurotransit --wait=false
   kubectl cnpg status eurotransit-orders-db -n eurotransit --verbose   # repeat / watch
   ```
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

## Results (fill during the run)

| Date | Operator | Primary killed | T0 (kill) | Primary flipped at | T1 (first acked write) | RTO | Acked orders checked | Missing | Budget consumed | Outcome |
|------|----------|----------------|-----------|--------------------|------------------------|-----|----------------------|---------|-----------------|---------|
|      |          |                |           |                    |                        |     |                      |         |                 |         |

## Conclusion

*(Did the failover meet the declared RTO/RPO? If RTO was blown by application reconnect rather
than DB promotion, split the two in the finding — the fix differs. Record actual sync-replication
write-latency overhead observed vs the k6 baseline.)*
