# ADR 0016 — Config-repo branch protection with a CI-app bypass actor

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** gitops, ci, security, governance
- **Supersedes / Superseded by:** —

---

## Context

`main` in `eurotransit-config` is the source of truth Argo CD reconciles from, so it
carries a branch-protection ruleset (`protect-main`, id `17927233`): required linear
history, no force-push, no deletion, and — the relevant rule — **pull requests with 1
approval + code-owner review** for every change.

That ruleset collides with the automated delivery loop from
[ADR 0007](0007-gitops-writeback-github-app.md): the app-repo CI `update-gitops` job
bumps the image tag in `values.yaml` and **pushes directly to `main`**. With no bypass
actor configured, the push was rejected:

```
remote: - Changes must be made through a pull request.
 ! [remote rejected] main -> main (push declined due to repository rule violations)  # GH013
```

So the design intent ("CI commits a tag bump → Argo CD reconciles", per
`.agent/agents/delivery-owner.md`) and the branch protection were in direct conflict.
Something had to give: either the bot goes through a reviewed PR (gating every deploy on
a human), or the bot is allowed to bypass the ruleset for its narrow write.

## Decision

Keep the `protect-main` ruleset **as-is for humans** and add the **CI GitHub App**
(`eurotransit-gitops-writeback`, App ID `4255821`, actor type `Integration`) as a
**bypass actor** with `bypass_mode: always`.

Concretely, on ruleset `17927233`:

```json
"bypass_actors": [
  { "actor_id": 4255821, "actor_type": "Integration", "bypass_mode": "always" }
]
```

Result:

- The org-owned CI app (and **only** it) can push image-tag bumps straight to `main`,
  keeping the delivery loop fully automatic — no human in the path of a routine bump.
- Every **human** contributor still goes through a reviewed PR (1 approval + code-owner
  review, linear history, no force-push). The protection is unchanged for people.
- The bypass is scoped to a single, auditable identity whose only permission is
  Contents: write on this one repo (ADR 0007), and whose commits are attributed to
  `eurotransit-gitops-writeback[bot]`.

## Alternatives considered

- **CI opens a PR + auto-merge (rejected for the routine loop).** Keeps "all changes via
  PR" literally true, but `protect-main` requires 1 approval + code-owner review, so
  auto-merge cannot complete without a human — either it stalls or we weaken the approval
  rule. That reintroduces a human gate on every image bump and defeats the pull-based
  automation. Also lands the change in the app repo, not here.
- **Human-approved PR per bump (rejected).** Most conservative — every deploy is
  reviewed — but breaks the hands-off GitOps loop the project is built around and adds
  approval latency to routine dev deploys.
- **Drop/loosen `protect-main` (rejected).** Would let anyone push unreviewed to the
  source of truth. The point is to protect it from *humans*; the fix is a scoped bypass,
  not removing the protection.

## Consequences

**Easier / better:**
- The documented automatic delivery loop works again with no workflow YAML changes — CI
  just re-runs and the push succeeds.
- Branch protection stays meaningful for humans; the source of truth is still not
  directly pushable by a person.
- The bypass is a single org-owned, least-privilege, per-run-token identity — auditable
  and not coupled to any person's account.

**Harder / risks:**
- **Whole-ruleset bypass.** A `bypass_mode: always` actor bypasses the *entire* ruleset
  (PR, linear history, force-push, deletion) for anything using that app's token — not
  just the PR rule. In practice the app's only token-holder is the `update-gitops` job,
  which does a single fast-forward commit, so the extra latitude is unused. Still, a
  compromised app private key could push arbitrary content to `main`; the mitigation is
  the ADR 0007 controls (Contents-only, single repo, short-lived per-run token, rotate
  on leak).
- **Invisible dependency.** The bypass lives in repo settings, not in Git, so a teammate
  auditing the ruleset could remove it and silently break CI write-back. This ADR plus
  the reference below exist so the bypass is not mistaken for a misconfiguration.
- **A bot commit skips code review.** Image-tag bumps are not human-reviewed. That is the
  intended trade for automatic delivery; correctness rests on CI having built/tested the
  image before the bump, and rollback stays `git revert` on `values.yaml`.

## Verification & ownership (agentic-coding policy)

Drafted with agent assistance; the team must verify before ratifying:

- [ ] Confirm the automatic-loop trade (bot bypass vs. human-gated PR) is the intended
      delivery model for the project timeline — this is the team's call.
- [ ] Verify the bypass actor is **exactly** App ID `4255821` / type `Integration` and no
      other actor (user, team, or `OrganizationAdmin`) was added:
      `gh api repos/cpo-g01-capstone/eurotransit-config/rulesets/17927233 --jq '.bypass_actors'`
- [ ] Re-run the app-repo CI on `main` and confirm the `update-gitops` push now succeeds
      and lands as `eurotransit-gitops-writeback[bot]`, with Argo CD reconciling the bump.
- [ ] Confirm humans still cannot push to `main` directly (a manual push is still
      rejected with GH013).

## References

- [ADR 0007 — Cross-repo GitOps Write-back via a GitHub App (not a PAT)](0007-gitops-writeback-github-app.md)
- [ADR 0013 — Config-repo CI Validation: Policy-as-code + Secret Scanning](0013-config-ci-validation.md)
- `.agent/agents/delivery-owner.md` — "CI updates Git; Argo CD deploys"; rollback = `git revert`
- Ruleset: `gh api repos/cpo-g01-capstone/eurotransit-config/rulesets/17927233`
- [GitHub docs — Bypass a ruleset](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/managing-rulesets-for-a-repository)
