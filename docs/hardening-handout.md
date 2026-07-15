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
| 4 | Enable PSA `warn`/`audit` on namespace | 🟠 High | Low | ✅ Done |
| 5 | Add Kafka authentication (SCRAM/mTLS) | 🟠 High | High |  ✅ Done  |
| 6 | Bump inventory/payments/notifications DB to 2 instances | 🟠 High | Low | Deferred (cluster CPU budget) |
| 7 | Block actuator endpoints at ingress level | 🟡 Medium | Low | Backlog |
| 8 | Add `X-Frame-Options` header | 🟡 Medium | Low | Backlog |
| 9 | Fix nginx security headers on `/assets/` | 🟡 Medium | Low | Backlog |
| 10 | Add `HEALTHCHECK` to Dockerfiles | 🟡 Medium | Low | Backlog |
| 11 | Move PSA to `enforce` on namespace | 🟠 High | Medium | Deferred (Kafka/CNPG pod compliance unverified) |

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

### H4 — Pod Security Admission labels (2026-07-14)

**Decision**: Apply PSA labels to the `eurotransit` namespace via the Argo CD Application's `spec.syncPolicy.managedNamespaceMetadata` (not a `kind: Namespace` manifest in the chart), set to `warn` + `audit` at the `restricted` level. `enforce` is deferred.

**Key design choices**:
- **`managedNamespaceMetadata` over a chart-owned `Namespace` resource**: the `eurotransit` namespace is created by Argo CD itself (`CreateNamespace=true` on the `eurotransit` Application — the chart never creates its own namespace; every template uses `{{ .Release.Namespace }}`, per the naming conventions in `CLAUDE.md`). A `kind: Namespace` template living in the chart would compete with Argo CD's own namespace bootstrap for ownership of the same object's labels on every sync. Putting the PSA labels on the Application resource itself keeps a single source of truth.
- **`warn` + `audit` only, not `enforce`, for now**: the five app Deployments already satisfy the `restricted` profile (C1 — `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, via the shared `_helpers.tpl` helpers). But the `KafkaNodePool`/`Kafka` CRs (Strimzi, `kafka/kafka-broker.yaml`) and the four `Cluster` CRs (CloudNativePG, `postgres/*.yaml`) also run in the `eurotransit` namespace (same AppProject scope, ADR 0011) and set no explicit `template.pod.securityContext` / container securityContext override — they rely on operator defaults, which have not been verified against `restricted` (the profile requires `runAsNonRoot`/`seccompProfile` to be explicitly set in the pod spec, not just implied by the image's `USER`). Jumping straight to `enforce` risks the operator failing to admit broker/DB pods. `warn`+`audit` surfaces violations (kubectl warnings + audit log) with zero admission risk.
- **`restricted`, not `baseline`**: matches the level already targeted and implemented for the app pods in C1.

**Follow-up before flipping to `enforce`** (tracked as action-plan item 11):
- Add an explicit `template.pod.securityContext` / `template.kafkaContainer.securityContext` (Strimzi) to `kafka/kafka-broker.yaml`.
- Verify the CloudNativePG-generated pod spec (operator pinned at chart `0.29.0` / CNPG `1.30.0`, `platform/cloudnative-pg/cloudnative-pg.yaml`) against `restricted`.
- Only then set `pod-security.kubernetes.io/enforce: restricted`.

**Files modified (eurotransit-config)**:
- `apps/eurotransit.yaml` — added `spec.syncPolicy.managedNamespaceMetadata.labels`


### H1 — Kafka SCRAM-SHA-512 authentication (2026-07-14)

**Decision**: Add SCRAM-SHA-512 authentication to the Kafka internal listener and create per-service KafkaUser CRs. TLS encryption deferred (traffic is namespace-internal only).

**Key design choices**:
- **SCRAM-SHA-512 over mTLS**: SCRAM is challenge-response — the password is never sent in cleartext even without TLS. mTLS would require per-service certificates and truststore management, adding complexity disproportionate to the internal-only traffic model.
- **TLS deferred**: All Kafka traffic is namespace-internal (`eurotransit` namespace). Enabling TLS would require configuring Java truststores on every service to trust the Strimzi-managed cluster CA. Accepted trade-off for internal traffic.
- **Per-service KafkaUser CRs**: Each service gets its own credentials (least-privilege). Strimzi auto-creates a Secret per KafkaUser containing `password` and a ready-made `sasl.jaas.config` string. There is **no `username` key** — the SCRAM username is the KafkaUser's `metadata.name` (see the second post-implementation bug below).
- **Shared Helm helper (`eurotransit.kafkaSaslEnv`)**: A single helper outputs 3 SASL env vars: security protocol, mechanism, and `SPRING_KAFKA_PROPERTIES_SASL_JAAS_CONFIG` mounted **directly from the secret's `sasl.jaas.config` key**. The alternative — a literal `KAFKA_USER` plus a `password` secretKeyRef, assembled into the JAAS string with `$(VAR)` substitution — was rejected: it hand-rebuilds a string Strimzi already ships verbatim, and every extra moving part (two env vars, `$(VAR)` ordering, JAAS quoting/escaping) is a place to fail. With the direct mount, Strimzi owns the JAAS format end to end and a password rotation only needs a pod restart.
- **userOperator re-enabled**: Adds ~200Mi to the entity-operator pod — accepted as the cost of authenticated Kafka access.

**Files modified (eurotransit-config)**:
- `kafka/kafka-broker.yaml` — added `authentication.type: scram-sha-512`, re-enabled `userOperator`
- `kafka/kafka-users.yaml` — **[NEW]** 5 KafkaUser CRs (catalog, orders, inventory, payments, notifications)
- `deploy/charts/eurotransit/templates/_helpers.tpl` — new `kafkaSaslEnv` helper
- `deploy/charts/eurotransit/values.yaml` — added `kafkaUserSecret` per service
- All 7 deployment templates (5 services + canary + green) — added `kafkaSaslEnv` include

**Post-implementation verification (2026-07-14) found and fixed a blocking bug**:
`kafka/kafka-users.yaml` was authored with `apiVersion: kafka.strimzi.io/v1beta2` on all 5
`KafkaUser` CRs. The Strimzi operator is pinned to 1.1.0 (ADR 0004), which serves **only**
`kafka.strimzi.io/v1` — the exact same class of issue already documented in
[ADR 0014](adr/0014-strimzi-v1-api-migration.md) for `Kafka`/`KafkaNodePool`/`KafkaTopic`, and
already called out for future Kafka CRs in `.agent/agents/delivery-owner.md`. Left as `v1beta2`,
Argo CD would fail to sync the `KafkaUser` CRs (`no matches for kind "KafkaUser" in version
"kafka.strimzi.io/v1beta2"`) — no per-service Secrets would be created, and since the broker
listener now *requires* SCRAM-SHA-512 auth, every service would fail to connect to Kafka
(a full outage of the async pipeline, strictly worse than the original H1 finding). Confirmed
against the Strimzi 1.1.0 release notes (v1beta2/v1beta1/v1alpha1 dropped for all CRDs from
1.0.0 onward) before fixing. **Fix**: changed all 5 CRs to `apiVersion: kafka.strimzi.io/v1`,
with an inline comment referencing ADR 0014 to prevent regression.
`helm template` on the chart renders cleanly and the rendered env vars match the KafkaUser
secret names in `values.yaml`; live cluster verification (`kubectl get crd kafkausers... `,
Argo CD sync status) is still pending because the local k3d cluster was not running at review
time — re-run the ADR 0014 verification checklist against `kafkausers.kafka.strimzi.io` once
the cluster is up.

**Second post-implementation bug, caught live after the #95 merge (2026-07-14)**:
the original `kafkaSaslEnv` helper pulled `KAFKA_USER` from the KafkaUser secret via a
`secretKeyRef` on a `username` key — but Strimzi SCRAM-SHA-512 user secrets contain only
`password` and `sasl.jaas.config` (the username is the KafkaUser's name). Schema-valid, so
`helm lint`/kubeconform passed; the kubelet rejected it at container creation and every new
ReplicaSet pod across all five services wedged in `CreateContainerConfigError`
(`couldn't find key username in Secret eurotransit/eurotransit-orders`). The pre-#95 pods
kept serving, so the app was Degraded, not down. **Fix** (issue #97, PR #98, agent-log
Case 22): the helper now mounts the secret's `sasl.jaas.config` key directly — the design
described above is the post-fix state. Lesson: operator-generated secrets have a contract,
not a guessable shape; verify actual key names against a live secret or the operator docs
before consuming them in templates.

---

### Deferred items

| Item | Reason |
|------|--------|
| H2 — Kafka persistent storage | Cluster CPU/memory budget too tight (ADR 0005, 3× B2s_v2 nodes) |
| H3 — DB multi-instance | Same cluster budget constraint — adding instances would exceed the 6 vCPU quota |
| H4 — PSA `enforce` | Strimzi Kafka / CloudNativePG pods in `eurotransit` don't yet set an explicit `securityContext` — unverified against `restricted`; only the app Deployments (C1) are confirmed compliant |
| H1 — TLS encryption on Kafka | Traffic is namespace-internal; SCRAM auth provides authentication without TLS overhead |
