# ADR 0019 — Single-approval review policy (CODEOWNERS flattened)

- **Status:** Accepted (implemented in config #28/#29 and app #9/#10; this ADR records the rationale)
- **Date:** 2026-07-11
- **Deciders:** whole team
- **Related:** `.github/CODEOWNERS` (both repos), ADR 0013 (CI validation), ADR 0016
  (branch protection with CI bypass)

## Context

Both repositories used path-based CODEOWNERS: each area (charts, platform, design docs,
service code) required a review from its specific owner, and a few collective files were
annotated as requiring approval from all five members. Combined with the `main` ruleset
(`require_code_owner_review: true`, 1 approving review), this meant a PR touching several
areas needed the *specific* owners to be available.

In practice, with a five-person team working in parallel bursts, this became the main
merge bottleneck: work stacked up in long-lived branches, PRs were merged into *each
other* instead of `main` (see the EM-40→EM-42 chain), and `main` lagged days behind the
actual state of the work — which defeats the point of a reconciliation-based delivery
loop, where `main` must be the truth.

## Decision

**One approval from any team member is enough for anything, in both repositories.**

- CODEOWNERS keeps a single catch-all rule listing all five members; every path-specific
  rule is commented out (kept in place, easy to re-enable).
- With the catch-all, the ruleset's `require_code_owner_review` is satisfied by an
  approval from *any* member — the branch protection itself is unchanged.
- Role ownership (delivery, data, async, observability, resilience) remains as
  **advisory guidance** in `docs/agents/` and the role docs: it tells you *who to ask*,
  it no longer *blocks the merge*.

## Why this is acceptable

The review gate was never the only safety net. The technical gates stay mandatory and
are unaffected:

- config repo: `validate.yml` (helm lint + template + kubeconform), kube-linter
  policy-as-code, gitleaks secret scanning (ADR 0013);
- app repo: build + tests on every PR, image scanning and provenance on `main`;
- Argo CD reconciliation makes any bad merge visible and revertible via `git revert`
  (rollback is a one-commit operation by design).

The cost we accept: a reviewer may approve changes outside their specialty. Mitigation:
non-trivial cross-area changes should still tag the relevant owner in the PR description
— as a courtesy and for knowledge sharing, not as a gate.

## Consequences

- Collective files (`agent-log.md`, `capstone-dod.md`, `postmortem.md`) no longer require
  five approvals; their headers are updated accordingly. Substantive changes to those
  files should still be *discussed* by everyone — the requirement moves from mechanics to
  team practice.
- If review quality degrades (e.g. a broken chart merged with a rubber-stamp approval),
  re-enable the relevant commented block in CODEOWNERS and record the reversal here.
