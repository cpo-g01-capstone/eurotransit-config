# ADR 0015 — Argo CD GitHub webhook via a patch-mode SealedSecret

- **Status:** Accepted (team ratification 2026-07-17 — webhook configured and verified by the team: deliveries 200, push-triggered reconcile observed)
- **Date:** 2026-07-11
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** argocd, gitops, secrets, delivery
- **Supersedes / Superseded by:** —

---

## Context

Argo CD reconciles the config repo by **polling** (default ~180s + jitter). That lag is
noticeable in a live demo: a merged image-tag bump (ADR 0007) or manifest fix sits idle
for up to three minutes before Argo notices. A **signed GitHub push webhook** to
`https://argocd.eurotransit.vojtechn.dev/api/webhook` drops that to seconds — GitHub POSTs
on every push and Argo refreshes the affected apps immediately.

The webhook must be authenticated: Argo CD verifies GitHub's `X-Hub-Signature` against a
shared secret. That secret has to be stored, and our secrets policy forbids plaintext in
Git (SealedSecrets only). Two facts constrain *where* it can live:

1. **Argo reads the webhook secret from a hardcoded location** — the key
   `webhook.github.secret` **inside the `argocd-secret` object**. Unlike the Dex GitHub
   OAuth credentials (ADR/EM-39), which `argocd-cm` pulls in via `$argocd-github-oauth:key`
   substitution, the webhook secret has **no `$secret:key` indirection**. It cannot live in
   its own separately-named Secret; it must be a key *in `argocd-secret`*.
2. **`argocd-secret` is delicate.** It is created empty by the upstream install and
   populated at *runtime* with `server.secretkey` (signs session JWTs) and
   `admin.password`. Clobbering it logs everyone out or crashloops `argocd-server` — the
   documented lab04 incident. The `argocd` self-manage app already guards this with
   `ignoreDifferences` on `argocd-secret` `/data` (`bootstrap/apps/argocd.yaml`).

So we need to add exactly one key to `argocd-secret` without replacing it, and without a
plaintext secret in Git.

## Decision

Enable the webhook and inject its shared secret with a **patch-mode SealedSecret that
merges into `argocd-secret`**:

1. **Webhook is primary; polling is a tightened fallback.** Set
   `timeout.reconciliation: 30s` + `jitter: 5s` in `bootstrap/install/patch-argocd-cm.yaml`
   so a missed/failed delivery still converges quickly (not the 180s default).
2. **Secret target is `argocd-secret`, key `webhook.github.secret`.** The plaintext source
   (`platform/argocd/secrets/webhook-github-secret.yaml`, gitignored) is sealed to
   `*.sealed.yaml`; only the sealed form is committed.
3. **Patch-merge, not replace.** The SealedSecret carries three annotations so the
   controller merges the one key instead of overwriting the whole Secret:
   - `sealedsecrets.bitnami.com/managed: "true"` — may modify a Secret it didn't create
   - `sealedsecrets.bitnami.com/patch: "true"` — merge the key; don't replace the Secret
   - `sealedsecrets.bitnami.com/skip-set-owner-references: "true"` — so deleting the
     SealedSecret can't cascade-delete `argocd-secret`
4. **Durable annotations via kustomize, not Helm.** The controller reads patch-mode from
   the *live* target, so `managed` + `patch` must persist on `argocd-secret` itself. This
   install is kustomize-based (ADR/EM), so a strategic-merge patch
   (`bootstrap/install/patch-argocd-secret.yaml`, annotations only) provides them — the
   kustomize-native equivalent of the Argo Helm chart's `configs.secret.annotations`. Safe
   because the self-manage app `ignoreDifferences` on `/data` leaves the runtime keys
   (and the merged webhook key) untouched.
5. **No IngressRoute change.** The existing Argo IngressRoute matches
   `Host(argocd.eurotransit.vojtechn.dev)` with no path filter, so `/api/webhook` already
   routes to `argocd-server`.

## Alternatives considered

- **Standalone `argocd-github-webhook` Secret + `$`-substitution (rejected — does not
  work).** Mirroring the OAuth pattern (own Secret, `app.kubernetes.io/part-of: argocd`
  label) is tempting, but Argo has no `$`-reference for the webhook secret — it reads
  `webhook.github.secret` directly from `argocd-secret`. A separately-named Secret is
  silently ignored and the webhook never authenticates. (This was a real mistake caught in
  review; recorded so it isn't retried.)
- **Polling only, no webhook (rejected).** Zero new secrets, but the ~3-min lag is poor for
  the demo and for tight feedback during canary/blue-green work.
- **Plaintext webhook secret / raw `kubectl` Secret (rejected).** Violates the SealedSecret
  secrets policy; the value would leak in Git history.
- **Replace `argocd-secret` wholesale via the SealedSecret (rejected — dangerous).** Wipes
  `server.secretkey`/`admin.password`; the `patch` annotation exists precisely to avoid it.

## Consequences

**Easier / better:**
- Config changes reconcile in seconds; the demo shows GitOps reacting to a merge live.
- The shared secret stays sealed in Git and merges cleanly into `argocd-secret`.
- Polling remains as a safety net, so a dropped webhook delivery is not a silent stall.

**Harder / risks:**
- **Patch-mode into `argocd-secret` is delicate.** Getting the annotations wrong can
  replace the Secret (wiping `server.secretkey`) or cascade-delete it (owner reference).
  Mitigated by the three annotations, the durable kustomize patch, and the self-manage
  app's `ignoreDifferences`. Apply order matters: the `managed`/`patch` annotations must be
  live on `argocd-secret` **before** the SealedSecret is processed.
- **Coupled to Argo's hardcoded key.** If a future Argo version changes how the webhook
  secret is sourced, revisit this. The secret's location is not our choice.
- **One more shared secret to rotate.** Rotating means resealing and updating the GitHub
  webhook config with the same value.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] After apply, `argocd-secret` shows **all** keys — `server.secretkey`,
      `admin.password`, `admin.passwordMtime`, `webhook.github.secret` — and an **empty**
      `ownerReferences` (decoupled):
      `kubectl -n argocd get secret argocd-secret -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`
- [ ] `bootstrap/install/patch-argocd-secret.yaml` renders the two annotations onto
      `argocd-secret` (`kubectl kustomize bootstrap/install`) and the self-manage app stays
      Synced/Healthy after it reconciles.
- [ ] GitHub → webhook → **Recent Deliveries** shows `200`; a test push reconciles the app
      in seconds rather than waiting for the 30s poll.
- [ ] Confirm the sealed secret targets `name: argocd-secret` (NOT a standalone name) and
      carries all three annotations.

## References

- Runbook (lab04, source pattern): `lab04/.../docs/argocd-webhook-sealed-secret.md`
- Files: `bootstrap/install/patch-argocd-secret.yaml`, `patch-argocd-cm.yaml`,
  `platform/argocd/secrets/webhook-github-secret.sealed.yaml`,
  `bootstrap/apps/argocd.yaml` (the `argocd-secret` `/data` `ignoreDifferences`)
- [ADR 0007 — Cross-repo GitOps Write-back via a GitHub App](0007-gitops-writeback-github-app.md)
- PR #27 / EM-43
