# ADR 0021 — HA replicas for stateful services and declared RTO/RPO

- **Status:** Proposed (drafted for team ratification via this PR)
- **Date:** 2026-07-11
- **Deciders:** _@marcodonatucci (drafted), @MauroC0l + @vojtech-n (data + delivery owners), full team to ratify_
- **Context tags:** data, kafka, postgres, chaos, capacity
- **Supersedes / Superseded by:** amends the "operating discipline" replica counts in ADR 0005

---

## Context

Chaos experiments CE-4 (Kafka partition) and CE-5 (CloudNativePG failover) are blocked on
the team's HA decision: with a single Kafka broker and a single Postgres instance there is nothing to
partition or fail over to. The same vote requires the team to declare RTO/RPO for the Orders database
*before* running CE-5, so the experiment verifies a stated objective instead of retrofitting one.

The constraint is the ADR 0005 capacity budget: 3× `Standard_B2s_v2` = ~5.5 allocatable vCPU,
with CPU already the binding resource. ADR 0005's initial discipline assumed *1 Kafka broker*
and *Postgres primary + 1 standby*.

## Decision

### Kafka: 3 dual-role brokers

`KafkaNodePool dual-role` goes to **`replicas: 3`** with cluster defaults
`default.replication.factor: 3`, `min.insync.replicas: 2` (and the offsets/transaction internal
topics at RF 3 / min-ISR 2). All five business topics move to **RF 3**.

The team voted for a real replication quorum over the ADR 0005 single-broker discipline: CE-4
can then demonstrate that losing/partitioning **one broker does not lose acked writes and the
pipeline converges**, which is the actual claim the capstone asks us to prove. To keep the CPU
bill bounded, brokers run lean: 250m request / 500m limit and a fixed 512 MiB JVM heap each
(~750m total requests — accepted trade-off, see Consequences).

### Postgres: 2 instances with synchronous replication

`eurotransit-orders-db` goes to **`instances: 2`** (primary + 1 standby) with **synchronous
replication** (`method: any`, `number: 1`, `dataDurability: preferred`). Two instances — not the
three in the original task sketch — because one standby is exactly what CE-5 needs (a promotion
target) and a third instance would spend another 250m CPU request without changing what the
experiment can demonstrate. Other databases (inventory, payments, notifications) stay at 1
instance: they are not the subject of CE-5 and the budget does not allow blanket HA.

### Declared RTO/RPO for the Orders database

- **RTO = 60 s** — from primary loss to checkout writes succeeding again (standby promoted,
  `-rw` service repointed, application reconnected).
- **RPO = 0** for the single-failure scenario (loss of the primary): synchronous replication
  means a commit is acked only once the standby has it, so no acknowledged order can be lost.
  **Honesty bound:** `dataDurability: preferred` degrades to async when the standby is
  unavailable, so RPO = 0 does **not** cover the double-failure case (standby down, then primary
  lost). We accept this: `required` durability with a single standby would freeze all writes on
  any standby outage, which is worse than the risk it removes at this scale.

CE-5 passes only if the observed failover meets both numbers.

## Alternatives considered

- **1 broker + budget ADR (ADR 0005 discipline).** Partition chaos would only show
  client↔broker disconnection and recovery, not replication surviving a broker loss. Rejected by
  team vote in favour of the stronger demonstration, accepting the CPU cost.
- **3 Postgres instances.** More production-like (a standby remains after promotion) but +250m
  CPU request for no additional evidence in CE-5. Rejected on budget.
- **Async replication with RPO ≈ 0 "best effort".** Honest but weak: the CE-5 report could not
  claim zero data loss by design, only by observation. Rejected — sync replication is cheap at
  demo load.
- **`dataDurability: required`.** Guarantees RPO = 0 even in double failures, but with one
  standby it turns any standby outage into a full write outage. Rejected.

## Consequences

- **Positive:** CE-4 and CE-5 are unblocked with claims worth proving; acked Kafka writes
  survive one broker loss; acked Postgres commits survive primary loss; RTO/RPO are stated
  before the experiment, as the capstone method requires.
- **CPU budget impact (the accepted cost):** +2 brokers (~500m extra requests) + 1 Postgres
  standby (+250m) lands on a cluster ADR 0005 already called CPU-tight. Mitigations: lean broker
  resources/heap (above), the ADR 0005 discipline stays in force (tear down canary/blue-green
  copies right after demos, moderate k6 VUs, `az aks stop` when idle), and if pods go `Pending`
  or throttling inflates the money-path p95, the fallback is scaling the *staging/demo extras*
  down — not the HA replicas under test. Watch `container_cpu_cfs_throttled_seconds` during k6.
- **One-time topic recreation:** the Strimzi topic operator cannot raise the replication factor
  of existing topics without Cruise Control (KafkaTopic goes `NotReady`). Broker storage is
  ephemeral and pre-production: after the 3-broker pool is Ready, delete the five KafkaTopics
  once and let Argo CD re-sync them at RF 3 (in-flight events are lost — coordinate the moment).
  Documented in `kafka/kafka-topics.yaml` and the CE-4 runbook.
- **Write latency:** synchronous replication adds one intra-cluster round-trip to every Orders
  commit. Expected to be well inside the 500 ms checkout p95 (same-node-pool network); verify
  against the k6 baseline after merge.
- **Kafka pod anti-affinity:** with 3 nodes and 3 brokers the scheduler usually spreads them,
  but nothing enforces it yet — the topology-spread work (ADR 0023) should cover Kafka too, otherwise CE-3/CE-4
  evidence is weaker if two brokers share a node.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; replica counts, RTO/RPO numbers and the durability trade-off are
team decisions (recorded by this ADR). Before ratifying:

- [ ] Team confirms the vote (3 brokers / 2 Postgres instances) and the RTO/RPO numbers (60 s / 0
      with the stated single-failure bound).
- [ ] After merge: 3 broker pods + 2 `orders-db` pods Running, no `Pending` pods
      (`kubectl top nodes` within budget).
- [ ] Topic recreation performed once; all five KafkaTopics `Ready` at RF 3.
- [ ] `kubectl cnpg status eurotransit-orders-db` shows streaming replication in sync mode.
- [ ] CE-4 / CE-5 executed against the declared numbers (reports in `docs/chaos-experiments/`).

## References

- ADR 0005 (capacity budget; amended replica discipline) · ADR 0004 (operator pinning)
- Team vote of 2026-07-11, recorded by this ADR
- `docs/chaos-experiments/ce-4-kafka-partition.md`, `ce-5-cnpg-failover.md`
- CNPG synchronous replication: <https://cloudnative-pg.io/documentation/current/replication/>
