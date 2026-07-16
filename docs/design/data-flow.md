# Data Flow — EuroTransit 

This document describes **where data lives and how it moves** through the money path: the
per-service datastores, the exact event payloads on each Kafka topic, the synchronous HTTP
payloads, and what each service writes and reads at every step. Companion to
[control-flow.md](control-flow.md), which covers the *control* side (states, retries,
compensations).

> **Schema provenance.** Every schema below is taken from the **actual code**: the Flyway
> migrations under `backend/<service>/src/main/resources/db/migration/` (applied in order —
> the *effective* schema is the composition of all of them) cross-checked against the R2DBC
> entity classes. `eurotransit-config/scripts/seed-db.sh` is ops tooling, **not** a schema
> source: it happens to match today, but the migrations are the single source of truth.
> This matters for `orders`: V2 added seven columns (customer, route, pricing…) that were
> **never used by the entity and were dropped in V4**, and V3 replaced the `order_status`
> PostgreSQL ENUM with `VARCHAR(50)`. Anyone reading only V1 — or a seed script — gets the
> wrong schema.

## Data ownership at a glance

Database-per-service: no table is shared, and no service reads another service's database.
The only cross-service data reads are the synchronous `POST /payments/authorize` call
(ADR 0018) and Catalog's **startup-only** snapshot `GET /inventory/routes` (issue #31).
Everything else travels inside Kafka events — e.g. Notifications never calls back to Orders;
what it needs rides in the event.

| Service | Store | Contents |
|---|---|---|
| orders | `ordersdb` (PostgreSQL) | `orders`, `processed_events`, `idempotency_records` |
| inventory | `inventorydb` (PostgreSQL) | `routes`, `reservations`, `processed_events` |
| payments | `paymentsdb` (PostgreSQL) | `payment_intents`, `processed_events` *(legacy, unused — see below)* |
| notifications | `notificationsdb` (PostgreSQL) | `sent_notifications` |
| catalog | **none — in-memory only** | `RouteCache` (ConcurrentHashMap) + `seenReservations` set |

The authoritative seat count and the **price authority** live in Inventory: the order total is
computed there (`route.price × seats`) and travels downstream inside `inventory-reserved` —
Payments authorizes the amount it is handed, it never computes one.

## Data flow diagram

Cylinders are datastores, yellow pills are Kafka topics, red is failure/compensation data.
Solid arrows carry the payloads shown; dashed arrows are failure-path data.

```mermaid
flowchart TD
    SPA["React SPA"]

    subgraph catalog["Catalog (8081) — stateless"]
        CACHE[("RouteCache — in-memory<br/>ConcurrentHashMap&lt;UUID, CatalogRoute&gt;<br/>+ seenReservations set")]
    end

    subgraph orders["Orders (8082)"]
        ODB[("ordersdb<br/>orders · processed_events ·<br/>idempotency_records")]
    end

    subgraph inventory["Inventory (8083)"]
        IDB[("inventorydb<br/>routes · reservations ·<br/>processed_events")]
    end

    subgraph payments["Payments (8084)"]
        PDB[("paymentsdb<br/>payment_intents ·<br/>processed_events (legacy, unused)")]
    end

    subgraph notifications["Notifications (8085)"]
        NDB[("notificationsdb<br/>sent_notifications")]
    end

    T1(["order-placed"])
    T2(["inventory-reserved"])
    T3(["payment-authorized"])
    T4(["order-confirmed"])
    T5(["order-failed"])
    DLT(["order-confirmed.DLT"])

    SPA -->|"GET /catalog — advisory<br/>availability (may lag)"| CACHE
    SPA -->|"POST /orders {routeId, seats}<br/>+ Idempotency-Key header"| ODB
    SPA -->|"GET /orders/{id} — status polling"| ODB

    ODB -->|"write: orders row (DRAFT) +<br/>idempotency_records (cached response)"| T1
    T1 -->|"{orderId, routeId, seats,<br/>idempotencyKey, timestamp}"| IDB
    IDB -->|"write: routes.available_seats −seats,<br/>reservations row, processed_events"| T2
    T2 -->|"{orderId, routeId, seats, reservationId,<br/>amount = price × seats, timestamp}"| ODB
    T2 -->|"advisory decrement<br/>(dedup by reservationId)"| CACHE
    IDB -->|"GET /inventory/routes —<br/>startup snapshot, replace-all"| CACHE

    ODB -->|"POST /payments/authorize {orderId, amount}<br/>Idempotency-Key = orderId"| PDB
    PDB -->|"write: payment_intents row<br/>(UNIQUE order_id)"| T3
    T3 -->|"{orderId, paymentId,<br/>amount, timestamp}"| ODB
    ODB -->|"write: orders RESERVED → CONFIRMED<br/>+ processed_events"| T4
    T4 -->|"{orderId, timestamp}"| NDB
    NDB -->|"write: sent_notifications<br/>PENDING → SENT"| MAIL["log stub +<br/>notifications_sent_total"]

    IDB -.->|"{orderId, reason: SOLD_OUT, timestamp}"| T5
    ODB -.->|"{orderId, reason, timestamp}<br/>(payment retries exhausted)"| T5
    T5 -.->|"write: orders → FAILED"| ODB
    T5 -.->|"write: reservations RESERVED → RELEASED,<br/>routes.available_seats +seats"| IDB
    NDB -.->|"failed record, unchanged payload"| DLT

    subgraph legend["Legend"]
        L1[("Datastore")]
        L2(["Kafka topic"])
        L3["Failure / compensation data"]
        L1 ~~~ L2 ~~~ L3
    end
    DLT ~~~ L1

    classDef client fill:#edf2f7,stroke:#4a5568,color:#1a202c
    classDef ordersN fill:#bee3f8,stroke:#2b6cb0,color:#1a365d
    classDef invN fill:#c6f6d5,stroke:#2f855a,color:#22543d
    classDef payN fill:#e9d8fd,stroke:#6b46c1,color:#322659
    classDef notifN fill:#b2f5ea,stroke:#2c7a7b,color:#234e52
    classDef catN fill:#e2e8f0,stroke:#4a5568,color:#1a202c
    classDef topic fill:#fefcbf,stroke:#b7791f,color:#5f370e
    classDef failN fill:#fed7d7,stroke:#c53030,color:#63171b

    class SPA,L1 client
    class ODB ordersN
    class IDB invN
    class PDB payN
    class NDB,MAIL notifN
    class CACHE catN
    class T1,T2,T3,T4,L2 topic
    class T5,DLT,L3 failN
    style legend fill:transparent,stroke:#718096,stroke-dasharray: 5 5
    style orders fill:transparent,stroke:#2b6cb0
    style inventory fill:transparent,stroke:#2f855a
    style payments fill:transparent,stroke:#6b46c1
    style notifications fill:transparent,stroke:#2c7a7b
    style catalog fill:transparent,stroke:#4a5568
```

## Kafka event payloads

Shapes taken from the producer's event classes; consumers declare mirror DTOs
(`spring.json.value.default.type`, JSON serialization).

| Topic | Producer class | Payload |
|---|---|---|
| `order-placed` | `orders/event/OrderEvents.kt` | `orderId: UUID`, `routeId: UUID`, `seats: Int`, `timestamp: Instant`, `idempotencyKey: String` |
| `inventory-reserved` | `inventory/event/InventoryEvents.kt` | `orderId: UUID`, `routeId: UUID`, `seats: Int`, `reservationId: UUID`, `amount: BigDecimal`, `timestamp: Instant` |
| `payment-authorized` | `payments/event/PaymentEvents.kt` | `orderId: UUID`, `paymentId: UUID`, `amount: BigDecimal`, `timestamp: Instant` |
| `order-confirmed` | `orders/event/OrderEvents.kt` | `orderId: UUID`, `timestamp: Instant` |
| `order-failed` | Orders & Inventory recoverers | `orderId: UUID`, `reason: String` (`"SOLD_OUT"` / exhaustion message), `timestamp: Instant` |
| `order-confirmed.DLT` | Notifications recoverer | the failed `order-confirmed` record, unchanged |

Contract subtleties, all encoded in the consumer DTOs:

- **`payment-authorized.amount` is nullable on the Orders consumer** — Jackson silently dropped
  the field before the audit fix (#19); nullable keeps pre-fix events deserializable.
- **Notifications reads `orderId` as `String`** (not UUID) and declares an optional
  `customerContact` defaulting to `customer@demo.eurotransit.test`: the Orders producer sends
  only `{orderId, timestamp}`. When the field was required, Jackson rejected every real event
  and the first live checkout went straight to the DLT.
- **`order-failed` carries only the orderId and reason** — deliberately no seat/route data:
  Inventory owns the reservation lookup, so the event cannot go stale.
- **Catalog dedups deliveries in memory** by `reservationId` (a `Set`, not a table) — enough
  within a pod's lifetime; a restart re-baselines via snapshot anyway (ADR 0006, #31).

## Synchronous HTTP payloads

| Call | Request | Response |
|---|---|---|
| `POST /orders` (SPA → Orders) | header `Idempotency-Key` (required), body `{routeId: UUID, seats: Int}` | `202 {orderId, status: "DRAFT", message}`; duplicate key → `200` cached body; over rate limit → `429` + `Retry-After: 1` (no body, nothing persisted) |
| `GET /orders/{id}` (SPA → Orders) | — | `200 {orderId, status, message: ""}` read from `orders`; `404` if unknown |
| `POST /payments/authorize` (Orders → Payments, ADR 0018) | header `Idempotency-Key` = orderId (validated against body), body `{orderId: UUID, amount: BigDecimal}` | `200 {paymentId, orderId, amount, status: "AUTHORIZED"}`; key/body mismatch → `400` |
| `GET /inventory/routes` (Catalog → Inventory, startup only) | — | JSON array of route rows; Catalog ignores unknown fields (e.g. `version`) |
| `GET /catalog`, `GET /catalog/{id}` (SPA → Catalog) | — | `CatalogRoute` list/item from the in-memory cache — **advisory** availability |

## Database schemas (from the Flyway migrations + entities)

### ordersdb — effective schema after V1 → V4

V1 created the tables with a PostgreSQL ENUM `order_status`; V3 converted `status` to
`VARCHAR(50)` and dropped the type; V2 added seven order-detail columns
(`customer_id`, `route_id`, `seat_class`, `quantity`, `total_amount`, `failure_reason`,
`version`) that the `Order` entity never had — four were `NOT NULL` without defaults, so every
INSERT would have failed — and **V4 dropped them all**. The entity enum has no `PAID` either
(removed with the synchronous authorize). What actually exists:

```mermaid
erDiagram
    orders {
        uuid id PK
        varchar status "VARCHAR(50), DRAFT | RESERVED | CONFIRMED | FAILED (V3: was PG ENUM; V1 also had PAID)"
        timestamptz created_at
        timestamptz updated_at
    }
    processed_events {
        varchar event_id PK "VARCHAR(512) = {orderId}:{eventType}"
        timestamptz processed_at
    }
    idempotency_records {
        varchar idempotency_key PK "VARCHAR(255) = client Idempotency-Key header"
        jsonb response_payload "cached POST /orders response"
        timestamptz created_at
    }
```

Indexes: `idx_orders_status`, `idx_orders_created_at`, `idx_processed_events_processed_at`.

### inventorydb

```mermaid
erDiagram
    routes {
        uuid id PK
        varchar origin
        varchar destination
        timestamptz departure_time
        int total_seats
        int available_seats "guarded by conditional UPDATE: available_seats >= :seats"
        decimal price "DECIMAL(10,2) — the price authority"
        int version "optimistic lock"
    }
    reservations {
        uuid id PK
        uuid order_id UK "UNIQUE(order_id, route_id) — no double reservation"
        uuid route_id FK
        int seats
        varchar status "RESERVED | RELEASED (default RESERVED)"
        timestamptz created_at
    }
    processed_events {
        varchar event_id PK "{orderId}:{eventType}"
        timestamptz processed_at
    }
    routes ||--o{ reservations : "route_id"
```

Partial index `idx_routes_available` on `available_seats > 0`. V2 seeds two deterministic demo
routes (`…0001` 100 seats, `…00ce` 2 seats) with `ON CONFLICT DO NOTHING` — the k6 and chaos
harnesses target them by fixed id.

### paymentsdb

```mermaid
erDiagram
    payment_intents {
        uuid id PK
        uuid order_id UK "UNIQUE — no double charge per order"
        decimal amount "DECIMAL(10,2)"
        varchar currency "default EUR"
        varchar status "default AUTHORIZED"
        varchar idempotency_key UK "= {orderId}:payment"
        timestamptz created_at
        timestamptz updated_at
    }
    processed_events {
        varchar event_id PK "LEGACY — unused since ADR 0018"
        timestamptz processed_at
    }
```

**Legacy note:** `processed_events` and the `InventoryReservedEvent` DTO in
`payments/event/PaymentEvents.kt` are residue of the pre-ADR-0018 design, when Payments
consumed `inventory-reserved` from Kafka. The service has no `@KafkaListener` today; its
idempotency lives entirely in the two unique indexes on `payment_intents`.

### notificationsdb

```mermaid
erDiagram
    sent_notifications {
        varchar order_id PK "VARCHAR(255) — String, not UUID"
        varchar status "CHECK: PENDING | SENT | FAILED (two-phase row, ADR-002/003)"
        timestamptz created_at
        timestamptz updated_at
    }
```

`status` is `VARCHAR` + `CHECK`, not a PG ENUM, to avoid R2DBC enum-codec complexity. The
two-phase protocol: `claim()` inserts `PENDING` (insert-if-absent), the send happens, then
`UPDATE → SENT`. A redelivery finding `SENT`/`FAILED` is a no-op; finding `PENDING` retries
the send.

### Catalog — deliberately no database

`RouteCache` is a `ConcurrentHashMap<UUID, CatalogRoute>` (id, origin, destination,
departureTime, totalSeats, availableSeats, price) plus a `seenReservations` set. State is
disposable by design (AP/EL — ADR 0006): at startup it serves a hardcoded fallback seed
(mirroring inventory's V2 migration), hydrates **once** from `GET /inventory/routes` with
capped-backoff retries (replace-all, not merge — routes Inventory no longer knows must
disappear), then stays warm on `inventory-reserved` deltas with `auto.offset.reset=latest`.
Consequence for ops: a SQL reseed is invisible to Catalog until a restart
(`just catalog-refresh`).

## Data lifecycle of one order

| Step | Service | Writes | Reads |
|---|---|---|---|
| `POST /orders` | Orders | TX: `orders` row (DRAFT) + `idempotency_records` row (cached JSONB response) | `idempotency_records` (dedup check) |
| `order-placed` consumed | Inventory | TX: `routes.available_seats −= seats` (conditional, version-checked) + `reservations` row + `processed_events` | `processed_events`, `reservations` (existing?), `routes` (price, seats, version) |
| `inventory-reserved` consumed | Orders | `orders` DRAFT→RESERVED; `processed_events` **only after** successful authorize | `processed_events` |
| `inventory-reserved` consumed | Catalog | in-memory: advisory `availableSeats` decrement | `seenReservations` |
| `/payments/authorize` called | Payments | `payment_intents` row (or none, on replay) | `payment_intents` by `order_id` |
| `payment-authorized` consumed | Orders | TX: `orders` RESERVED→CONFIRMED + `processed_events` | `processed_events` |
| `order-confirmed` consumed | Notifications | `sent_notifications` claim PENDING, then → SENT | `sent_notifications` status |
| `order-failed` consumed | Orders | `orders` →FAILED (conditional) + `processed_events` | `processed_events` |
| `order-failed` consumed | Inventory | TX: `reservations` RESERVED→RELEASED + `routes.available_seats += seats` + `processed_events` | `processed_events`, `reservations` by `order_id` |

Two write-ordering invariants recur everywhere: **DB commit before Kafka publish**
(at-least-once safe — a crash between the two republishes, and consumers dedup) and, on the
payment step, **dedup record only after success** (so failed attempts are retried by
redelivery instead of being lost).

## Consistency model in data terms

The `order_id` is the logical join key across all four databases — there are **no physical
foreign keys across services**, only within `inventorydb`. Consistency is enforced per-store:
conditional state transitions in `orders`, the atomic seat UPDATE and
`UNIQUE(order_id, route_id)` in `inventorydb`, `UNIQUE(order_id)` in `paymentsdb`, and the
`sent_notifications` primary key. Inventory is the CP side (no oversell, ever); Catalog is the
AP side (browse never blocks, availability may lag). A declared bound: if Orders' recoverer
marks an order FAILED while a late `payment-authorized` lands, the order stays FAILED with an
`AUTHORIZED` intent in `paymentsdb` — the demo PSP never captures; a real one would need a
void/refund step.
