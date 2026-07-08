# Agent log

Records cases where agent-produced artifacts were incorrect, unsafe, or subtly wrong.
**Minimum three entries required before the live presentation. This file is graded.**

All five team members must approve changes to this file (see CODEOWNERS).

Custodian: @marcodonatucci (Observability & Verification).

| # | Date | Area | Summary |
|---|------|------|---------|
| 1 | 2026-06-20 | CI / eurotransit-app | Wrong `paths-filter` globs for service modules |
| 2 | 2026-06-19 | GitOps / eurotransit-config | Placeholder `TODO-TEAM` repo URL in Argo CD Applications |
| 3 | 2026-06-20 | Delivery / docs vs CI | ACR documented but GHCR implemented in workflow |
| 4 | 2026-07-08 | Async / eurotransit-config context docs | Notifications consumed-topics inconsistency (`order-confirmed` vs `notification-requested`) |
| 5 | 2026-07-08 | Async / eurotransit-app notifications | AI-designed `suspend` @KafkaListener silently swallowed handler exceptions (no retry/DLT) |
=======

---

## Case 1 — 2026-06-20 — CI path filters (eurotransit-app)

**What the AI produced:**
The initial `.github/workflows/ci.yml` stub used `dorny/paths-filter` globs such as
`backend/catalog/**`, `backend/orders/**`, etc., matching the *planned* layout in
`justfile` and `CODEOWNERS`, not the layout produced by the EM-13 scaffold
(`backend/catalog-service/**`, `backend/orders-service/**`, …).

**Why it was wrong:**
On a change confined to one service (e.g. only `backend/orders-service/`), the filter
would not match. The `images` job would skip that service entirely: no image rebuild,
no GitOps tag bump, and silent drift between code and cluster.

**How it was caught:**
Manual review while implementing EM-15 (Setup GitHub Actions CI), comparing the
workflow filters against `settings.gradle.kts` and the actual directory tree on `main`.

**How it was corrected:**
Updated every service filter to `backend/<service>-service/**` in
`feature/EM-15-Setup-github-actions-ci` (merged via app PR #2 / follow-up commits).

**Lesson learned:**
Before trusting AI-generated path filters, diff them against `settings.gradle.kts`
`include(...)` lines and a real `find backend -maxdepth 1 -type d`. Scaffold layout
and docs can diverge — the filesystem wins.

---

## Case 2 — 2026-06-19 — Argo CD placeholder repo URL (eurotransit-config)

**What the AI produced:**
Early bootstrap manifests `bootstrap/apps/platform.yaml` and
`bootstrap/apps/workloads.yaml` contained:

```yaml
repoURL: 'https://github.com/TODO-TEAM/eurotransit-config.git' # TO BE CHANGED
```

**Why it was wrong:**
Argo CD would fail to reconcile (or point at a non-existent org) once the app-of-apps
was applied. With `automated.selfHeal: true`, a bad source URL blocks the entire
GitOps loop — no platform components, no workloads.

**How it was caught:**
Kickoff / EM-11 review checklist before merging the platform bootstrap branch.

**How it was corrected:**
Replaced with `https://github.com/cpo-g01-capstone/eurotransit-config.git` before
merge to `main` (EM-11, config PR #6).

**Lesson learned:**
Search every generated manifest for `TODO`, `CHANGEME`, and placeholder hostnames
before the first `kubectl apply` / Argo sync. AI scaffolds often leave these behind.

---

## Case 3 — 2026-06-20 — Image registry mismatch (ACR vs GHCR)

**What the AI produced:**
Two inconsistent artifacts:
- `CLAUDE.md`, `.agent/context.md`, and `delivery-owner.md` describe **Azure Container
  Registry (ACR)** (`<acr>.azurecr.io`, `az` login, push only on `main`).
- The EM-15 CI workflow implementation uses **GHCR** (`REGISTRY: ghcr.io`,
  `docker/login-action` with `GITHUB_TOKEN`, `packages: write`).

**Why it was wrong:**
Subtly dangerous, not a compile failure: a teammate following `CLAUDE.md` would add
ACR secrets and `az acr login` steps (extra credentials, violates least-privilege),
while CI already pushes to GHCR. Conversely, Helm `values.yaml` examples still show
`*.azurecr.io` image repositories that CI will never populate.

**How it was caught:**
Cross-review during EM-15 implementation — workflow comments said GHCR but agent
context files still said ACR.

**How it was corrected:**
CI workflow committed with GHCR as the source of truth (app PR #2). **Follow-up
required:** update `CLAUDE.md`, `delivery-owner.md`, and Helm `values.yaml` image
repository fields to GHCR (or revert CI to ACR if the team chooses Azure — one
registry, documented everywhere).

**Lesson learned:**
Registry choice is a team decision, not something to split across “implementation”
and “docs”. After any AI-generated CI change, grep both repos for the old registry
string and align in the same PR.

---

## Case 4 — 2026-07-08 — Notifications consumed-topics inconsistency (eurotransit-config context docs)

> **Draft — pending team approval.** This entry was drafted by the agent while
> implementing the Notifications consumer. Per CODEOWNERS all five members must approve
> before it merges to `main`.

**What the AI produced:**
Two agent-generated context docs disagree on which topics the Notifications service consumes:
- `.agent/context/money-path.md` (step 7): Notifications consumes **`order-confirmed`** only.
- `.agent/context/kafka-topics.md`: lists Notifications as consumer of **both**
  `order-confirmed` **and** `notification-requested` (the latter with producer `Orders`).

No service actually produces `notification-requested` — no Orders code emits it, and the
money path never references it.

**Why it was wrong:**
Subtly wrong, not a compile failure. Taken literally, an implementer wiring Notifications
from `kafka-topics.md` would add a **second `@KafkaListener` on a topic that has no
producer** — a listener that never fires — or the team would create a `KafkaTopic` CR
(`notification-requested`) that is **orphaned**: declared infrastructure, never written,
never read. It also misleads the reader into thinking Orders must perform a dual-write
(`order-confirmed` **and** `notification-requested`) after confirmation, which — without a
transactional outbox — is itself a consistency hazard.

**How it was caught:**
Cross-checking `kafka-topics.md` against `money-path.md` while designing the Notifications
consumer (ADR-001, eurotransit-app), before writing the listener.

**How it was corrected:**
Resolved by **ADR-001** (eurotransit-app `docs/adr/`): Notifications consumes
`order-confirmed` only, consistent with the money path and with the team's
consistency-over-availability preference. **Follow-up required in this repo:** remove
`notification-requested` from `.agent/context/kafka-topics.md` and from any `KafkaTopic`
CRs, **or** annotate it explicitly as "reserved, not yet wired". Team decision + PR.

**Lesson learned:**
Event topology must be reconciled across `money-path.md` and `kafka-topics.md` in the same
change. A topic row with a producer/consumer that no code implements is a latent trap —
grep for every topic name across both repos and confirm a real producer *and* consumer
exist before declaring the CR.

---

## Case 5 — 2026-07-08 — `suspend` @KafkaListener silently swallowed exceptions (eurotransit-app)

> **Draft — pending team approval** (CODEOWNERS). Caught while implementing the Notifications
> consumer (ADR-001..004).

**What the AI produced:**
The AI-authored design (ADR-004 / the notifications spec) and the first implementation used a
Kotlin `suspend` @KafkaListener:

```kotlin
@KafkaListener(topics = ["order-confirmed"], containerFactory = "kafkaListenerContainerFactory")
suspend fun onOrderConfirmed(event: OrderConfirmedEvent) { service.handle(event) }
```

It compiled, and the **happy path passed** — messages were consumed and marked `SENT`.

**Why it was wrong (subtly):**
With this Spring Kafka version, a `suspend` @KafkaListener **does not propagate handler
exceptions to the container's `DefaultErrorHandler`**. When the send failed, the exception was
swallowed: **no bounded retry, no publish to `order-confirmed.DLT`, and the offset was still
committed** (`AckMode.RECORD`) — the failed notification was silently lost. The integration test
proved it: the recoverer ran **0** times and only **1** delivery attempt occurred. This defeats
the entire resilience design (ADR-003): "no lost notifications, poison messages parked in the
DLT". A green happy-path test hid a broken failure path — exactly the kind of gap the money path
must not have.

**How it was caught:**
The DLT integration test (`OrderConfirmedDltIT`) asserted that an always-failing send lands in
`order-confirmed.DLT` and the row becomes `FAILED`. It timed out; debug logging showed the
recoverer never fired and there were no retries.

**How it was corrected:**
Switched to a non-`suspend` handler that bridges to the suspending service with `runBlocking`,
taking the raw `ConsumerRecord` (Spring Kafka's typed-payload conversion returned `KafkaNull` for
an already-deserialized value on a non-suspend method):

```kotlin
@KafkaListener(topics = ["order-confirmed"], containerFactory = "kafkaListenerContainerFactory")
fun onOrderConfirmed(record: ConsumerRecord<String, OrderConfirmedEvent?>) {
    val event = record.value() ?: return
    runBlocking { service.handle(event) }
}
```

The exception now surfaces synchronously → `DefaultErrorHandler` retries → DLT + `FAILED`.
**Team decision required:** this uses `runBlocking`, which `CLAUDE.md` bans "outside bootstrap".
The consumer thread is a dedicated blocking poll loop (not a reactive context), so blocking here
is arguably correct, but the team must ratify the exception to the rule (or choose an alternative
bridge) and update ADR-004 / the spec accordingly.

**Lesson learned:**
A passing happy-path test is not evidence the failure path works — for money-path handlers,
always test the failure/DLT/redelivery paths explicitly. Framework "it compiles and consumes"
does not imply "errors are handled"; verify exception propagation end-to-end.
=======
