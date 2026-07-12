# Kafka topics — EuroTransit

Cluster name (Strimzi CR): `eurotransit-kafka`
Bootstrap service (internal FQDN): `eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092`
Spring Boot env var: `SPRING_KAFKA_BOOTSTRAP_SERVERS=eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092`

| Topic | Partitions | Retention | Producer | Consumer(s) |
|-------|-----------|-----------|----------|-------------|
| order-placed | 3 | 7 days | Orders | Inventory |
| inventory-reserved | 3 | 7 days | Inventory | Orders, Catalog (AP cache, app ADR 0006) |
| payment-authorized | 3 | 7 days | Payments | Orders |
| order-confirmed | 3 | 7 days | Orders | Notifications |
| order-failed | 3 | 7 days | Orders, Inventory (sold-out) | Inventory (seat release), Orders (mark FAILED) |
| order-confirmed.DLT | 3 | 7 days | Notifications error handler | — (manual inspection/replay) |
| notification-requested | 3 | 7 days | — (reserved, not wired — app ADR-001) | — |

All topics are declared as `KafkaTopic` CRs — auto-creation is disabled.
Producer/consumer columns reflect the code on `main` (grep `topics = [...]` /
`TOPIC_*` constants in eurotransit-app) — reconcile this table with
`money-path.md` in the same change whenever the event topology moves.
