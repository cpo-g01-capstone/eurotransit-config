# Idempotency scheme — Money path

*Owner: @MauroC0l*

## Idempotency key design

**Format:** `{orderId}:{eventType}` — a composite string using the order UUID and the Kafka
topic name as the event type identifier.

**Rationale:** The `orderId` correlates all events in a single checkout flow. Appending
the event type makes the key self-documenting and safe even if a service consumes
multiple event types for the same order.

**Storage:** Each service that consumes Kafka events maintains a `processed_events` table
in its own PostgreSQL database. The `event_id` column (VARCHAR(512), primary key) stores
the idempotency key. The insert happens inside the same database transaction as the
business logic — if the transaction rolls back (e.g. pod kill), the dedup record is NOT
persisted and the retry correctly reprocesses.

**HTTP idempotency (POST /orders):** The Orders service accepts an `Idempotency-Key`
HTTP header on `POST /orders`. This key is stored in the `idempotency_records` table
with the cached response payload. Duplicate requests return `200 OK` with the cached
response instead of creating a new order.

## Deduplication points

| Event | Consumer | Deduplication mechanism | Key | DB table |
|-------|----------|------------------------|-----|----------|
| `order-placed` | Inventory | `processed_events` table in `inventorydb` | `{orderId}:order-placed` | `processed_events` |
| `inventory-reserved` | Payments | `processed_events` table in `paymentsdb` | `{orderId}:inventory-reserved` | `processed_events` |
| `payment-authorized` | Orders | `processed_events` table in `ordersdb` | `{orderId}:payment-authorized` | `processed_events` |
| `order-confirmed` | Notifications | `processed_events` table (future — EM-22) | `{orderId}:order-confirmed` | `processed_events` |
| HTTP `POST /orders` | Orders | `idempotency_records` table in `ordersdb` | Client-supplied `Idempotency-Key` header | `idempotency_records` |

## Shared dedup pattern (Kafka consumers)

Every Kafka consumer follows this exact pattern:

```kotlin
suspend fun handleEvent(event: SomeEvent) {
    val eventId = "${event.orderId}:${EVENT_TYPE}"

    // 1. Check dedup table (read-before-write)
    if (processedEventRepository.existsByEventId(eventId)) {
        logger.info("Duplicate event $eventId — skipping")
        return  // Ack without reprocessing
    }

    // 2. Business logic + dedup record in ONE transaction
    transactionalOperator.executeAndAwait {
        doBusinessLogic(event)
        processedEventRepository.save(ProcessedEvent(eventId, Instant.now()))
    }

    // 3. Publish downstream event (outside TX)
    //    At-least-once is safe because the next consumer is also idempotent
    kafkaProducer.send(downstreamEvent)
}
```

**Why read-before-write?** The dedup check is a SELECT before INSERT. The INSERT
happens inside the business transaction. If the pod is killed mid-transaction, the
transaction rolls back — the dedup record is not saved — and the retry correctly
reprocesses. An insert-first approach would risk marking an event as "processed" when
the business logic never completed.

## Failure scenarios

| Scenario | What happens | Why it's safe |
|----------|-------------|---------------|
| Kafka redelivers `order-placed` after Inventory already processed it | Inventory checks `processed_events`, finds the key, skips | Dedup key in DB |
| Pod kill on Inventory mid-reservation (CE-2) | Transaction rolls back (no dedup record saved), Kafka redelivers, retry succeeds | Transactional dedup |
| Kafka partition heals and replays messages (CE-4) | All consumers check dedup tables, skip already-processed events | Dedup key in DB |
| Duplicate HTTP `POST /orders` with same `Idempotency-Key` | Orders returns cached response from `idempotency_records` | HTTP idempotency table |
| Payments pod restarts after authorizing but before ack | Kafka redelivers `inventory-reserved`, Payments checks `processed_events`, skips | Persistent dedup (not in-memory) |
