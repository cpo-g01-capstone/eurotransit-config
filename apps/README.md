# Workloads

This directory contains Argo CD `Application` manifests for EuroTransit workloads and data infrastructure.

## Microservices (planned)
- Catalog
- Orders
- Inventory
- Payments
- Notifications

## Data infrastructure
- **`data-infrastructure.yaml`** — syncs `postgres/` (CloudNativePG `Cluster` for Orders DB, EM-16)
