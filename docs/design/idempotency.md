# Idempotency scheme — Money path

*Owner: @MauroC0l*

## Idempotency key design

**Format:** `{orderId}:{eventType}` — a composite string using the order UUID and the Kafka
topic name as the event type identifier.

**Rationale:** The `orderId` correlates all events in a single checkout flow. Appending
the event type makes the key self-documenting and safe even if a service consumes
multiple event types for the same order.

**Storage:** Orders and Inventory each maintain a `processed_events` table in their own PostgreSQL
database. The `event_id` column (VARCHAR(512), primary key) stores the idempotency key. The insert
happens inside the same database transaction as the business logic — if the transaction rolls back
(e.g. pod kill), the dedup record is NOT persisted and the retry correctly reprocesses.

Not every Kafka consumer uses this scheme, by design: **Notifications** dedupes on its own
`sent_notifications` table (the two-phase row *is* its dedup record), and **Catalog** does not dedupe
at all. See the table below for the full picture.

**HTTP idempotency (POST /orders):** The Orders service accepts an `Idempotency-Key`
HTTP header on `POST /orders`. This key is stored in the `idempotency_records` table
with the cached response payload. Duplicate requests return `200 OK` with the cached
response instead of creating a new order.

## Deduplication points

| Event | Consumer | Deduplication mechanism | Key | DB table |
|-------|----------|------------------------|-----|----------|
| `order-placed` | Inventory | `processed_events` table in `inventorydb` | `{orderId}:order-placed` | `processed_events` |
| `inventory-reserved` | **Orders** | `processed_events` table in `ordersdb` | `{orderId}:inventory-reserved` | `processed_events` |
| `inventory-reserved` | **Catalog** | **none — deliberate** (AP cache tolerates skip/replay, app ADR 0006) | — | — |
| `payment-authorized` | Orders | `processed_events` table in `ordersdb` | `{orderId}:payment-authorized` | `processed_events` |
| `order-failed` | Inventory | `processed_events` table in `inventorydb` | `{orderId}:order-failed` | `processed_events` |
| `order-failed` | Orders | `processed_events` table in `ordersdb` | `{orderId}:order-failed:orders` ⚠️ | `processed_events` |
| `order-confirmed` | Notifications | two-phase `PENDING → SENT` row in `notificationsdb` (app ADR-002) | `{orderId}` alone | `sent_notifications` |
| HTTP `POST /payments/authorize` | Payments | `payment_intents.idempotency_key` unique index in `paymentsdb` | `{orderId}:payment` | `payment_intents` |
| HTTP `POST /orders` | Orders | `idempotency_records` table in `ordersdb` | Client-supplied `Idempotency-Key` header | `idempotency_records` |

⚠️ **Known deviation from the key format.** `order-failed` is the one event consumed by *two*
services, and Orders suffixes its key (`:orders`) while Inventory does not. The suffix is redundant —
the two services have separate databases, so the keys could never collide — but it is what the code
does (`OrderFailedConsumer.kt` in each service). Documented rather than silently "corrected": align
the code first, then this table.

> **Payments is not in this table as a Kafka consumer, and that is correct.** Since ADR 0018 the
> authorization is a synchronous HTTP call from Orders, so Payments has no `@KafkaListener` and
> nothing to deduplicate at the consumer level — its protection is the `UNIQUE(order_id)` +
> `UNIQUE(idempotency_key)` pair on `payment_intents`. The `processed_events` table in `paymentsdb`
> is a leftover of the old async stage and is **unused**.

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
| Duplicate HTTP `POST /orders` with same `Idempotency-Key` | Orders returns cached response (200, not 202) from `idempotency_records` | HTTP idempotency table |
| Payments pod restarts after authorizing but before responding | Orders' bounded retry (or a Kafka redelivery of `inventory-reserved`) re-issues `POST /authorize` with the same `Idempotency-Key`; Payments returns the existing intent | `UNIQUE(order_id)` on `payment_intents` — persistent, not in-memory |
| Orders' circuit breaker to Payments is OPEN | `CallNotPermittedException` fails fast → Kafka error handler redelivers with backoff; the order stays `RESERVED` | The redelivery *is* the queued-retry fallback (ADR 0018) |
| Notifications crashes between `PENDING` row and send | Redelivery finds the `PENDING` row and completes the send; a `SENT` row makes it a no-op | Two-phase `sent_notifications` row (app ADR-002/003) |
