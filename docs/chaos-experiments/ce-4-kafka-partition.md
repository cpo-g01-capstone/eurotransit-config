# CE-4 — Kafka network partition (one broker isolated)

*Capstone chaos experiment #4. Injection: Chaos Mesh `NetworkChaos` (`ce-4-kafka-partition.yaml`)
cuts one of the three brokers off from the whole `eurotransit` namespace for 5 minutes.
Prerequisite: the ADR 0021 topology (3 dual-role brokers, topics at RF 3, `min.insync.replicas: 2`)
is reconciled and the one-time topic recreation has been done — check all five KafkaTopics are
`Ready` at RF 3 before starting.*

## Hypothesis

Isolating one broker will NOT break the async money path and will NOT lose or duplicate events:

1. **KRaft quorum survives** (2 of 3 controllers) — the cluster keeps a leader and keeps serving;
2. **Producers keep acking**: partition leadership moves to the two reachable brokers; with RF 3
   and min ISR 2, every acked write is on ≥2 replicas, so nothing acked is lost;
3. **Consumers keep consuming** (possibly a lag spike while leadership moves), and consumer-side
   idempotency (`processed_events`) absorbs any redelivery — no double-processing;
4. **On heal**, the isolated broker rejoins, catches up (ISR back to 3), lag drains to ~0, and no
   order is missing or duplicated end-to-end.

## Steady state

- Checkout SLIs within SLO; consumer records-lag ≈ 0 (RED dashboard, Kafka panel).
- All five KafkaTopics `Ready`; `kubectl get kafka,kafkanodepool -n eurotransit` all Ready.
- Note the broker pods: `kubectl get pods -n eurotransit -l strimzi.io/name=eurotransit-kafka-kafka -o wide`.

## Method

1. Record steady state; seed a route and start continuous checkout load (curl/k6), noting the
   number of orders submitted and their IDs (same harness as CE-2).
2. `just chaos-enable` (once per cluster), then inject:
   ```bash
   just chaos ce-4-kafka-partition
   ```
   Identify the isolated broker: `kubectl describe networkchaos ce-4-kafka-partition -n chaos-testing`.
3. Observe for the 5-minute window (below).
4. Heal (or let the 5m duration expire):
   ```bash
   just chaos-clean ce-4-kafka-partition
   ```
5. Wait for convergence, then verify end-to-end: every submitted order reached exactly-once its
   terminal state (orders DB count + `processed_events` dedup table — same I1/I2/I3-style queries
   as the CE-2 pre-test).

## What to observe

- **Checkout SLIs** (RED dashboard): the sync entry (`POST /orders`) should be unaffected —
  reservation/authorization are sync; only the async tail (confirmation/notification) may lag.
- **Consumer records-lag** (RED dashboard, Kafka panel): expected spike while leadership moves,
  then drain after heal.
- **Producer errors in app logs**: brief `NOT_ENOUGH_REPLICAS`/timeouts are acceptable during
  leadership movement; sustained failures are not.
- **Broker state**: `kubectl get kafka -n eurotransit -o yaml | grep -A3 conditions`, under-replicated
  partitions on the two healthy brokers, and the isolated broker rejoining on heal.

## Pass / fail

- **PASS**: no checkout outage; no acked event lost (every submitted order converges to its
  terminal state); no duplicate side effects (dedup counts clean); lag returns to ~0 after heal.
- **FAIL**: checkout errors beyond the error budget; any order stuck/missing after convergence;
  double-processing visible in `processed_events` violations; broker fails to rejoin the ISR.

## Results (fill during the run)

| Date | Operator | Isolated broker | Orders submitted | Lag peak | Producer errors seen | Lost events | Duplicates | Time to converge after heal | Outcome |
|------|----------|-----------------|------------------|----------|----------------------|-------------|------------|-----------------------------|---------|
|      |          |                 |                  |          |                      |             |            |                             |         |

## Conclusion

*(Did the hypothesis hold? Record leadership-movement behaviour, any window where producers
blocked, and whether idempotency absorbed redeliveries. Feed scheduling findings — e.g. two
brokers on one node — into ADR 0023.)*
