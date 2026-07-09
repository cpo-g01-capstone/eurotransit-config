# Kafka topics — EuroTransit

Cluster name (Strimzi CR): `eurotransit-kafka`
Bootstrap service (internal FQDN): `eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092`
Spring Boot env var: `SPRING_KAFKA_BOOTSTRAP_SERVERS=eurotransit-kafka-kafka-bootstrap.eurotransit.svc.cluster.local:9092`

| Topic | Partitions | Retention | Producer | Consumer(s) |
|-------|-----------|-----------|----------|-------------|
| order-placed | 3 | 7 days | Orders | Inventory, Payments |
| inventory-reserved | 3 | 7 days | Inventory | Orders |
| payment-authorized | 3 | 7 days | Payments | Orders |
| order-confirmed | 3 | 7 days | Orders | Notifications |
| notification-requested | 3 | 7 days | Orders | Notifications |

All topics are declared as `KafkaTopic` CRs — auto-creation is disabled.
