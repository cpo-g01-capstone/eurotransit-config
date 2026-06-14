# Money path — step-by-step checkout trace

1. Client → Traefik (HTTPS) → Orders service (POST /orders)
2. Orders persists draft order in PostgreSQL, publishes `order-placed` to Kafka
3. Orders returns 202 Accepted immediately (async pipeline begins)
4. Inventory consumes `order-placed` → reserves seats (atomic/conditional SQL) → publishes `inventory-reserved`
5. Payments consumes `inventory-reserved` → authorizes payment (idempotency key) → publishes `payment-authorized`
6. Orders consumes `payment-authorized` → confirms order in DB → publishes `order-confirmed`
7. Notifications consumes `order-confirmed` → sends confirmation email
   - Notifications failure does NOT fail checkout (graceful degradation)

**Critical path for SLOs:** steps 1–6 (Notifications is out of the success criterion)
**Idempotency keys:** order ID + event type at every Kafka consumer handler
