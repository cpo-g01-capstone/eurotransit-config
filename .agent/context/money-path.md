# Money path — step-by-step checkout trace

1. Client → Traefik (HTTPS) → Orders service (POST /orders, `Idempotency-Key` header required)
2. Orders persists draft order in PostgreSQL, publishes `order-placed` to Kafka
3. Orders returns 202 Accepted immediately (async pipeline begins); a duplicate
   `Idempotency-Key` returns 200 with the cached response instead
4. Inventory consumes `order-placed` → reserves seats (atomic/conditional SQL) → publishes
   `inventory-reserved` (or `order-failed` when sold out)
5. Orders consumes `inventory-reserved` → order `DRAFT → RESERVED` → **authorizes the payment with a
   synchronous HTTP call** to Payments (`POST /payments/authorize`, `Idempotency-Key = orderId`),
   wrapped in a Resilience4j circuit breaker + bounded retry + dedicated connection pool (ADR 0018).
   This is the **only** synchronous cross-service call on the money path.
6. Payments authorizes idempotently (one `payment_intent` per order) → publishes `payment-authorized`
7. Orders consumes `payment-authorized` → order `RESERVED → CONFIRMED` → publishes `order-confirmed`
8. Notifications consumes `order-confirmed` → sends confirmation email
   - Notifications failure does NOT fail checkout (graceful degradation)

> **Payments does not consume from Kafka.** It has no `@KafkaListener`: it is reached only by the
> synchronous call in step 5 and only *produces* `payment-authorized`. (Before ADR 0018 the
> authorization was a Kafka stage consuming `inventory-reserved` — that pipeline no longer exists.)

**Order states:** `DRAFT → RESERVED → CONFIRMED`, or `→ FAILED` with seat-release compensation.
(There is no `PAID` state — it was removed with the synchronous authorize; see `Order.kt`.)

**Critical path for SLOs:** steps 1–7 (Notifications is out of the success criterion)

**Idempotency keys:** `{orderId}:{eventType}` at the Kafka consumer handlers of **Orders** and
**Inventory**, stored in each service's own `processed_events` table. Three deliberate exceptions:
- **Payments** — key `{orderId}:payment` on the `payment_intents.idempotency_key` unique index
- **Notifications** — the `sent_notifications` table keyed by `order_id` (app ADR-002)
- **Catalog** — no dedup at all: the AP cache tolerates a skipped or replayed event (app ADR 0006)
