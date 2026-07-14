# EuroTransit — Hardening Handout

> **Scope**: `eurotransit-config` repo (Helm chart, Kubernetes manifests, platform layer) + `eurotransit-app` repo (Dockerfiles, nginx config).
> **Date**: 2026-07-14
> **Method**: Static scan of all manifests, Dockerfiles, Helm values/templates, kube-linter config, gitleaks config, and platform components.

---

## Summary

| Severity | Count | Status |
|----------|-------|--------|
| 🔴 Critical | 2 | Open |
| 🟠 High | 4 | Open |
| 🟡 Medium | 4 | Open / Partially mitigated |
| 🟢 Good practices already in place | 7 | Done |

---

## 🔴 Critical Findings

### C1 — No `securityContext` on any Pod

**Files affected**: All deployment templates in `deploy/charts/eurotransit/templates/*/deployment*.yaml`

No deployment sets `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, or `drop: [ALL]` capabilities. Containers run as **root** by default.

The `.kube-linter.yaml` explicitly **excludes** `run-as-non-root` and `no-read-only-root-fs` checks, acknowledging this gap.

**Remediation** — add to every deployment template:

```yaml
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
```

> For Spring Boot pods, add a writable `/tmp` via `emptyDir`:
> ```yaml
> volumeMounts:
>   - name: tmp
>     mountPath: /tmp
> volumes:
>   - name: tmp
>     emptyDir: {}
> ```

After fixing, **re-enable** `run-as-non-root` and `no-read-only-root-fs` in `.kube-linter.yaml`.

---

### C2 — Dockerfiles run as root (no `USER` instruction)

**Files affected**:
- `backend/*/Dockerfile` (all 5 services) — `eclipse-temurin:21-jre-alpine`, no `USER`
- `frontend/Dockerfile` — `nginx:1.29-alpine`, no `USER`

**Remediation** — Backend example:
```dockerfile
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY ${JAR_FILE} app.jar
USER appuser
ENTRYPOINT ["java", "-jar", "app.jar"]
```

Frontend: use `USER nginx` (nginx:alpine ships with the `nginx` user, UID 101).

---

## 🟠 High Findings

### H1 — Kafka listener has no authentication and no TLS

**File**: `kafka/kafka-broker.yaml` (line 56-59)

```yaml
listeners:
  - name: plain
    port: 9092
    type: internal
    tls: false
```

No `authentication` block. The `userOperator` was explicitly removed. Any pod in the namespace can produce/consume from any topic without credentials.

**Remediation**: Enable `tls: true` and add SCRAM-SHA-512 or mTLS authentication. Re-enable the `userOperator` and create `KafkaUser` CRs per service.

---

### H2 — Kafka storage is `ephemeral`

**File**: `kafka/kafka-broker.yaml` (line 17)

```yaml
storage:
  type: ephemeral
```

A pod restart **loses all topic data**. Acceptable for dev/capstone but a critical risk in production.

**Remediation**: Switch to `persistent-claim` with a `StorageClass`.

---

### H3 — Three of four databases are single-instance (no HA)

**Files**:
- `postgres/eurotransit-inventory-db.yaml` — `instances: 1`
- `postgres/eurotransit-payments-db.yaml` — `instances: 1`
- `postgres/eurotransit-notifications-db.yaml` — `instances: 1`

Only `eurotransit-orders-db` has 2 instances with synchronous replication.

**Remediation**: Set `instances: 2` (minimum) with `synchronous` replication on payments-db at least (financial data). Add `affinity.podAntiAffinityType: required` as done in orders-db.

---

### H4 — No Pod Security Admission (PSA) enforcement

The kube-linter config comments reference "deferred hardening" for PSA. No namespace label enforces `pod-security.kubernetes.io/enforce: restricted`.

**Remediation**: Apply PSA labels to the `eurotransit` namespace:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: eurotransit
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

Start with `warn`/`audit` first, then move to `enforce` after fixing C1.

---

## 🟡 Medium Findings

### M1 — Ingress exposes Spring Boot Actuator endpoints

The `strip-api` middleware strips `/api` prefix, meaning `/api/catalog/actuator/...` forwards to `/catalog/actuator/...` on the backend. If Spring Boot actuator is not restricted, health/env/beans endpoints are publicly reachable.

**Remediation**: Ensure Spring Boot `management.endpoints.web.exposure.include` is limited to `health,prometheus` (verify in app-repo `application.yml`). Or add a Traefik middleware to block `/api/*/actuator/**` paths.

---

### M2 — Missing `X-Frame-Options` header on nginx

**File**: `frontend/deploy/nginx.conf`

CSP has `frame-ancestors 'none'` (good), but the legacy `X-Frame-Options: DENY` header is missing for older browser support.

**Remediation**: Add `add_header X-Frame-Options "DENY" always;` to nginx.conf.

---

### M3 — No `HEALTHCHECK` in Dockerfiles

None of the 6 Dockerfiles include a `HEALTHCHECK` instruction. While Kubernetes probes handle this at the orchestration layer, the Docker-level healthcheck is useful for local development and `docker compose`.

**Remediation** (low priority):
```dockerfile
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/actuator/health/liveness || exit 1
```

---

### M4 — Security headers lost on `/assets/` sub-location

**File**: `frontend/deploy/nginx.conf` (line 31-34)

The `/assets/` location block uses `add_header` which **replaces** (not appends to) the server-level headers in nginx. The security headers (CSP, HSTS, etc.) are not inherited by this block.

**Remediation**: Repeat the security headers inside the `/assets/` location block, or use `add_header` only at the server level and use `expires` directive differently.

---

## 🟢 Good Practices Already in Place

| Practice | Evidence |
|----------|----------|
| ✅ NetworkPolicies (default-deny + explicit allows) | `templates/shared/networkpolicy.yaml` — 7 policies |
| ✅ TLS ingress with cert-manager (Let's Encrypt) | `certificate.yaml`, `ingress.yaml` with HTTP→HTTPS redirect |
| ✅ DB credentials via Kubernetes Secrets (not hardcoded) | All deployments use `secretKeyRef` for DB passwords |
| ✅ Sealed Secrets for secret management | `platform/sealed-secrets/`, `.gitleaks.toml` allowlists encrypted blobs |
| ✅ Gitleaks secret scanning enabled | `.gitleaks.toml` with default rules |
| ✅ Kube-linter policy-as-code gate | `.kube-linter.yaml` in CI pipeline |
| ✅ Security headers on frontend | CSP, HSTS, nosniff, Referrer-Policy, Permissions-Policy in nginx.conf |
| ✅ Resource limits/requests on all pods | Every deployment has `resources.requests` and `resources.limits` |
| ✅ PodDisruptionBudgets on all services | `templates/shared/pdb-*.yaml` for all 6 services |
| ✅ Immutable image tags (CI-enforced SHA) | kube-linter comment confirms tag override in CI |

---

## Prioritized Action Plan

| # | Action | Severity | Effort | Status |
|---|--------|----------|--------|--------|
| 1 | Add `USER` to all Dockerfiles | 🔴 Critical | Low | ✅ Done |
| 2 | Add `securityContext` to all deployments | 🔴 Critical | Medium | ✅ Done |
| 3 | Re-enable kube-linter checks after fixes | 🔴 Critical | Low | ✅ Done |
| 4 | Enable PSA `warn`/`audit` on namespace | 🟠 High | Low | Planned |
| 5 | Add Kafka authentication (SCRAM/mTLS) | 🟠 High | High | Planned |
| 6 | Bump inventory/payments/notifications DB to 2 instances | 🟠 High | Low | Deferred (cluster CPU budget) |
| 7 | Block actuator endpoints at ingress level | 🟡 Medium | Low | Backlog |
| 8 | Add `X-Frame-Options` header | 🟡 Medium | Low | Backlog |
| 9 | Fix nginx security headers on `/assets/` | 🟡 Medium | Low | Backlog |
| 10 | Add `HEALTHCHECK` to Dockerfiles | 🟡 Medium | Low | Backlog |

---

## Decision Log

### C1 — securityContext implementation (2026-07-14)

**Decision**: Add pod-level and container-level security context to ALL 8 deployment templates via shared Helm helpers (`eurotransit.podSecurityContext`, `eurotransit.containerSecurityContext`) in `_helpers.tpl`.

**Key design choices**:
- **Shared helpers over inline YAML**: Centralized in `_helpers.tpl` to ensure consistency across all deployments (5 services + frontend + canary + green). A change in one place propagates to all.
- **`readOnlyRootFilesystem: true` + emptyDir `/tmp`**: Spring Boot (JVM) needs `/tmp` for temp files, class data sharing, and NIO. Mounting an `emptyDir` is the standard pattern — it's writable but ephemeral and size-limited.
- **Frontend nginx volumes**: nginx needs writable `/var/cache/nginx`, `/var/run` (pid file), and `/tmp`. The Dockerfile also moves the pid file to `/tmp`.
- **`seccompProfile: RuntimeDefault`**: Required by the `restricted` PSA level — blocks unneeded syscalls at the kernel level.
- **`capabilities.drop: [ALL]`**: No Linux capability is needed by a JVM or nginx serving on port 8080 (unprivileged port).

**Files modified (eurotransit-config)**:
- `deploy/charts/eurotransit/templates/_helpers.tpl` — 2 new helpers
- `deploy/charts/eurotransit/templates/catalog/deployment.yaml`
- `deploy/charts/eurotransit/templates/catalog/deployment-green.yaml`
- `deploy/charts/eurotransit/templates/orders/deployment.yaml`
- `deploy/charts/eurotransit/templates/orders/deployment-canary.yaml`
- `deploy/charts/eurotransit/templates/inventory/deployment.yaml`
- `deploy/charts/eurotransit/templates/payments/deployment.yaml`
- `deploy/charts/eurotransit/templates/notifications/deployment.yaml`
- `deploy/charts/eurotransit/templates/frontend/deployment.yaml`
- `.kube-linter.yaml` — re-enabled `run-as-non-root` and `no-read-only-root-fs`

---

### C2 — Dockerfile non-root user (2026-07-14)

**Decision**: Add a dedicated non-root user (UID 10001) to all backend Dockerfiles; use the stock `nginx` user (UID 101) for the frontend.

**Key design choices**:
- **UID 10001 (not a name)**: `USER 10001` in the Dockerfile matches any `runAsUser` constraint and avoids name-resolution issues in minimal Alpine images.
- **System user (`adduser -S`)**: No home directory, no login shell — minimal attack surface.
- **nginx non-root**: Required `sed` to move the pid file from `/var/run/nginx.pid` to `/tmp/nginx.pid`, plus `chown` on cache/log dirs. Port 8080 is already unprivileged, so no `NET_BIND_SERVICE` needed.

**Files modified (eurotransit-app)**:
- `backend/catalog-service/Dockerfile`
- `backend/orders-service/Dockerfile`
- `backend/inventory-service/Dockerfile`
- `backend/payments-service/Dockerfile`
- `backend/notifications-service/Dockerfile`
- `frontend/Dockerfile`

---

### Deferred items

| Item | Reason |
|------|--------|
| H2 — Kafka persistent storage | Cluster CPU/memory budget too tight (ADR 0005, 3× B2s_v2 nodes) |
| H3 — DB multi-instance | Same cluster budget constraint — adding instances would exceed the 6 vCPU quota |
