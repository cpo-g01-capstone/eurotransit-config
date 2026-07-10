# ADR 0013 — Config-repo CI validation: policy-as-code + secret scanning (CI-only)

- **Status:** Proposed
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** ci, gitops, security, policy-as-code
- **Supersedes / Superseded by:** —

---

## Context

The config repo had no CI. On `main` every commit is a deploy (Argo reconciles), so a bad
manifest merges straight to the cluster. CLAUDE.md's agentic-coding threat model names a
**policy-as-code review gate** — "helm lint + `helm template | kubeval` on every config-repo
PR" — as the control that stops a bad (possibly agent-generated) manifest before Argo applies
it. We also want to keep plaintext secrets out of Git (only `*.sealed.yaml` is allowed), and to
catch a typo'd image tag before it becomes an `ImagePullBackOff`.

Two design axes to settle: **where** policy runs (CI vs in-cluster admission), and **how** we
scan for secrets (server-side, client-side, or both).

## Decision

**A single `validate.yml` workflow** runs on PRs and pushes to `main` (path-filtered). It is the
review gate. Steps:

1. **`just helm-verify` + `just helm-schema`** — the *same recipes run locally* (helm lint +
   template + no-plaintext-Secret + no-public-Service; kubeconform against k8s + CRD schemas).
   One source of truth, no CI/local drift.
2. **Policy-as-code = kube-linter, CI-only.** No in-cluster admission controller (Kyverno /
   Gatekeeper). kube-linter lints the rendered chart against the manifest-checkable "common
   mistakes" in CLAUDE.md. It runs **blocking** on the checks the chart already passes; five
   checks are **excluded with documented reasons** in `.kube-linter.yaml` — one render artifact
   (`latest-tag`; CI overwrites the placeholder with a Git-SHA) and four deferred-hardening
   checks (`run-as-non-root`, `no-read-only-root-fs`, `no-anti-affinity`,
   `pdb-unhealthy-pod-eviction-policy`) tracked in `docs/delivery/network-policy-checklist.md`.
   Re-enable each as its gap closes.
3. **Secret scanning, two layers.** `gitleaks` runs in CI (the enforced gate) **and** as an
   opt-in local `.githooks/pre-commit` hook (fast feedback, installed via `just install-hooks`).
   Hooks are bypassable and not installed on clone, so CI is the real enforcement; the hook is
   defense-in-depth. `.gitleaks.toml` allowlists SealedSecret ciphertext, prose `.md` docs, and
   public Azure identifiers. A `git ls-files` convention check also blocks any unsealed
   `secrets/*.yaml`, `*.pem`, `*.key`.
4. **ACR tag-existence** is a separate OIDC job using a **read-only** identity
   (`id-eurotransit-config-ci`, AcrPull — ADR 0010 / `infra/acr-oidc`). It **soft-skips** with a
   notice when the config-repo OIDC secrets aren't set — it's a best-effort pre-merge safety net,
   not load-bearing, so its absence doesn't break anything (contrast the app-repo write-back,
   which must fail).

Tool versions are **pinned** (kubeconform `v0.6.7`, kube-linter `v0.8.3`, gitleaks `v8.30.1`).

## Alternatives considered

- **In-cluster admission (Kyverno / Gatekeeper) enforcing the same policies.** Rejected — a new
  platform component on a 6-vCPU budget (ADR 0005) for a single-cluster capstone; a CI gate
  already satisfies the review-gate requirement. The lab05 reference used Kyverno because it had
  an admission controller; we don't. Revisit if admission-time enforcement is ever required.
- **Kyverno CLI / Conftest custom policies instead of kube-linter.** More tailored to our exact
  rules but more to write/maintain; kube-linter gives broad, zero-config coverage now. A few
  custom rules can be added later for project-specific invariants kube-linter can't express.
- **Making kube-linter blocking on *all* default checks.** Rejected for now — would require chart
  `securityContext` / anti-affinity changes that are team-owned (resilience / PSA) and could
  break the Spring pods without testing. Deferred via documented exclusions, not ignored.
- **`gitleaks-action` instead of the binary.** Rejected — its v2 needs a `GITLEAKS_LICENSE` for
  org repos; the pinned binary avoids that.
- **CI-only secret scan (no local hook).** Rejected — the local hook gives fast feedback before a
  secret ever leaves the machine; cheap to add alongside the CI gate.

## Consequences

- **Easier / safer:** a bad manifest, a policy violation, or a leaked secret fails a PR instead
  of reaching the cluster; CI enforces the *same* checks devs run locally (`just`); the ACR
  identity for CI is read-only (least privilege).
- **Harder / risks:**
  - **Excluded kube-linter checks are deferred hardening**, not resolved — they must be
    re-enabled as `securityContext`/anti-affinity land. Tracked in the network-policy checklist.
  - **Pinned tool versions** don't auto-update; bump deliberately.
  - **`gitleaks` `generic-api-key` is noisy** — the allowlist (docs, Azure identifiers) needs
    occasional maintenance; over-broad allowlisting could hide a real secret in docs (mitigated:
    real secrets live only in sealed manifests, which are scanned).
  - **Local hooks are opt-in and bypassable** — they are not a guarantee; CI is.

## Verification & ownership (agentic-coding policy)

- [ ] `validate.yml` runs on a PR and blocks a deliberately broken manifest (bad `kind`, a
      plaintext `kind: Secret`, a `hostNetwork: true`).
- [ ] Make `validate` a **required status check** on `main` branch protection (+ 1 review) — this
      is what makes the gate actually block merges.
- [ ] Re-enable a kube-linter exclusion once its chart gap is closed (start with securityContext).
- [ ] Confirm the local hook via `just install-hooks` blocks a staged plaintext secret.

## References

- `.github/workflows/validate.yml`, `.kube-linter.yaml`, `.gitleaks.toml`, `.githooks/pre-commit`.
- ADR 0003 (kubeconform compensating control), ADR 0010 (ACR OIDC / read-only identity),
  ADR 0011 (AppProject blast radius).
- `docs/delivery/network-policy-checklist.md` — the deferred hardening the exclusions track.
- CLAUDE.md — agentic-coding policy-as-code review gate; "common mistakes to reject".
