# Data flow — EuroTransit money path

*Owner: @vojtech-n. Edges verified against the application code (producers/consumers
per topic) and the live broker consumer groups, 2026-07-13. Companion docs:
[`service-boundaries.md`](service-boundaries.md), [`consistency.md`](consistency.md),
[`idempotency.md`](idempotency.md); topic ↔ producer/consumer table in
`.agent/context/kafka-topics.md` — keep the two in sync in the same PR (app ADR-001).*

## System data-flow diagram

```mermaid
flowchart TB
    client([Client])
    traefik["Traefik<br/>(IngressRoute — the only public entrypoint)"]
    spa["Frontend SPA<br/>(static)"]

    subgraph services["eurotransit namespace — all ClusterIP"]
        catalog["Catalog<br/>(stateless, event-fed cache)"]
        orders["Orders<br/>(workflow orchestrator)"]
        payments["Payments<br/>(authorize, idempotent)"]
        inventory["Inventory<br/>(atomic seat reservation)"]
        notifications["Notifications<br/>(graceful degradation)"]
    end

    subgraph kafka["Kafka — eurotransit-kafka (3 brokers, RF 3, min ISR 2)"]
        t_placed{{"order-placed"}}
        t_reserved{{"inventory-reserved"}}
        t_authorized{{"payment-authorized"}}
        t_confirmed{{"order-confirmed"}}
        t_failed{{"order-failed"}}
        t_dlt{{"order-confirmed.DLT"}}
    end

    ordersdb[("ordersdb<br/>orders, processed_events,<br/>idempotency_records")]
    inventorydb[("inventorydb<br/>routes, reservations,<br/>processed_events")]
    paymentsdb[("paymentsdb<br/>payment_intents,<br/>processed_events")]
    notificationsdb[("notificationsdb<br/>sent_notifications")]
    email["Confirmation<br/>(simulated send)"]

    client --> traefik
    traefik -->|"/*"| spa
    traefik -->|"GET /api/catalog"| catalog
    traefik -->|"1 · POST /api/orders (202)<br/>GET /api/orders/{id}"| orders

    orders -->|"2 · publish"| t_placed
    t_placed -->|"3 · consume, reserve atomically"| inventory
    inventory -->|"publish"| t_reserved
    t_reserved -->|"4 · consume → RESERVED"| orders
    t_reserved -.->|"3b · cache warm<br/>(eventually consistent)"| catalog

    orders ==>|"5 · sync authorize — REST,<br/>2 s timeout, breaker + bulkhead<br/>(ADR 0018)"| payments
    payments -->|"6 · publish"| t_authorized
    t_authorized -->|"7 · consume → PAID"| orders
    orders -->|"8 · publish (→ CONFIRMED)"| t_confirmed
    t_confirmed -->|"consume, dedup, send"| notifications
    notifications --> email
    notifications -.->|"poison messages"| t_dlt

    orders -.->|"9 · redeliveries exhausted:<br/>publish (case-24 guard upstream)"| t_failed
    t_failed -.->|"9a · release seats<br/>(compensation)"| inventory
    t_failed -.->|"9b · apply FAILED"| orders

    orders --- ordersdb
    inventory --- inventorydb
    payments --- paymentsdb
    notifications --- notificationsdb

    classDef db fill:#e8f0fe,stroke:#4a6da7,color:#1a1a2e
    classDef topic fill:#fdf3d8,stroke:#b8860b,color:#1a1a2e
    class ordersdb,inventorydb,paymentsdb,notificationsdb db
    class t_placed,t_reserved,t_authorized,t_confirmed,t_failed,t_dlt topic
```

Solid arrows = the happy money path (numbered); the bold arrow (5) is the single
synchronous cross-service call; dashed arrows = compensation, dead-lettering, and the
eventually-consistent cache feed.

## The money path, step by step

1. Client `POST /api/orders` through Traefik → Orders persists the order (`DRAFT`) and
   acks **202** immediately — the async pipeline does the rest.
2. Orders publishes `order-placed`.
3. Inventory consumes it: atomic conditional `UPDATE` on `available_seats` +
   `processed_events` dedup row **in the same transaction** ([consistency
   model](consistency.md), CP) → publishes `inventory-reserved`.
   **3b.** Catalog consumes the same event to keep its browse cache warm — it may lag;
   that is accepted staleness (app ADR 0006).
4. Orders consumes `inventory-reserved` → order `RESERVED`.
5. Orders calls Payments **synchronously**: REST, 2 s timeout, Resilience4j circuit
   breaker + bulkhead (ADR 0018). This is the only sync cross-service edge — and the
   CE-1 chaos target.
6. Payments authorizes idempotently (`UNIQUE(order_id)` + idempotency key, exactly one
   `payment_intent` per order) and publishes `payment-authorized`.
7. Orders consumes it → order `PAID` → publishes `order-confirmed` (8), order
   `CONFIRMED`.
8. Notifications consumes `order-confirmed`, dedups via `sent_notifications`
   (per app ADR-002), sends the confirmation. Failures must not propagate to checkout;
   poison messages go to `order-confirmed.DLT`.
9. **Failure branch:** if payment-stage redeliveries are exhausted, Orders publishes
   `order-failed` (the case-24 guard first checks the order has not already reached a
   terminal SUCCESS state). Inventory consumes it to **release the reserved seats**
   (9a); Orders applies the `FAILED` transition (9b).

Order states: `DRAFT → RESERVED → PAID → CONFIRMED`, or `→ FAILED` with compensation.

## Invariants carried by this flow

- Every consumer is idempotent: `processed_events` keyed `{orderId}:{eventType}`
  ([idempotency scheme](idempotency.md)) — at-least-once delivery never
  double-processes.
- Exactly one `payment_intent` per order (DB-level `UNIQUE`).
- No oversell: the reservation is a conditional atomic `UPDATE`; only one caller wins
  the last seat.
- Notifications can fail entirely without failing checkout (graceful degradation).
- `notification-requested` is declared as a topic CR but **unwired** (app ADR-001) —
  deliberately absent from this diagram.
