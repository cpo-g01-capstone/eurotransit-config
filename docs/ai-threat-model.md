# AI coding-agent threat model

*Required by the capstone spec ("Agentic coding policy", rule 2: "The agent is an actor in
your system, and you must reason about its blast radius"). This is the canonical copy; the
summary in `CLAUDE.md` §"Blast radius of this agent" must stay consistent with it.*

*Team-owned. Reviewed like any PR (single approval — ADR 0019). Last aligned: 2026-07-12.*

## Who the agent is

Coding agents (Claude Code and equivalents) generate artifacts in both repositories:
service scaffolding, Helm templates, manifests, dashboards, test harnesses, docs drafts.
Per the project policy (`CLAUDE.md` §"Agentic coding policy") they may **not** decide
service decomposition, consistency models, SLOs, failure-mode mapping, chaos hypotheses,
or postmortem content.

## Credentials and blast radius (least privilege)

- **The agent holds no standing credentials of its own.** It runs under a team member's
  workstation identity; anything it pushes lands on a branch, never `main`
  (branch protection ruleset, `.github` repo).
- **Cluster:** the agent has no direct cluster credentials. The only path from agent
  output to the cluster is: PR → human review → merge to `main` → Argo CD reconcile.
- **Cross-repo CI write-back** (the only automated write into this repo) uses a
  **short-lived GitHub App installation token** — Contents: write scoped to
  `eurotransit-config` only, minted per CI run (ADR 0007). Never a PAT, never
  `GITHUB_TOKEN`. Image pushes use Azure OIDC federation, no registry password (ADR 0010).

## Review gate before merge

- Every agent-generated PR requires human approval (CODEOWNERS + ADR 0019).
- Policy-as-code on every config-repo PR (ADR 0013): `helm lint`, template render,
  kubeconform schema validation, gitleaks (no plaintext secrets), kube-linter.
- Known agent failure modes are codified as reject-and-log rules in `CLAUDE.md`
  §"Common mistakes to reject" (liveness probing downstream, cause-based alerts,
  over-permissive RBAC, non-idempotent handlers, …).

## Worst case

The agent proposes a subtly bad manifest, review misses it, Argo CD (selfHeal+prune)
applies it and a money-path service degrades. Containment: symptom-based burn-rate
alerts page on the user-visible impact; rollback is one `git revert` on the config repo
(never `kubectl`); Argo CD self-heals to the reverted state; the case is documented in
`docs/agent-log.md`. This exact loop has been exercised in practice — see agent-log
cases 13, 14 and 16 (bad manifests caught at review or at sync, corrected via PR).

## Verification duty

"If you can't explain why the code works, don't merge it." Every caught agent mistake
is recorded in [`agent-log.md`](agent-log.md) (18 cases as of 2026-07-12; ≥3 required).
