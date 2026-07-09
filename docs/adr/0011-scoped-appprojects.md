# ADR 0011 — Scoped AppProjects (platform + eurotransit) instead of `default`

- **Status:** Proposed
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** gitops, security, argocd
- **Supersedes / Superseded by:** —

---

## Context

Every Argo CD Application ran under `project: default`. The `default` AppProject permits
**any source repo → any cluster → any namespace → any resource kind** — the widest possible
blast radius. That is precisely the risk called out in the agentic-coding threat model
(`CLAUDE.md`): an agent (or a mistaken human) proposes a bad manifest, Argo applies it, and
nothing scopes what it may touch.

An `AppProject` is a whitelist — `sourceRepos`, `destinations` (cluster + namespace), and
cluster/namespace resource kinds — plus a boundary for project-scoped RBAC. The question is
not *whether* to scope, but *how tightly*, given that the platform legitimately needs broad,
cluster-scoped rights (CRDs, ClusterRoles, webhooks across ~8 namespaces) while the five app
services need almost none.

## Decision

**Two AppProjects, matched to the two privilege tiers already present in the app-of-apps**
(`bootstrap/apps/projects.yaml`):

| Project | Applications | Scope |
|---|---|---|
| `platform` | `argocd` (self-mgmt), `platform`, `workloads` | source = config repo; dest = in-cluster, **any** namespace; **all** cluster + namespaced kinds |
| `eurotransit` | `eurotransit`, `eurotransit-kafka`, `eurotransit-data` | source = config repo; dest = in-cluster, **`eurotransit` namespace only**; **no cluster-scoped kinds except `Namespace`** (for `CreateNamespace=true`); any namespaced kind |

- Both projects restrict `sourceRepos` to the config repo, so no Application can be pointed at
  an arbitrary repo.
- The `eurotransit` project is the real win: the app tier — the code path most likely to
  receive a bad or agent-generated manifest — **cannot** create a `ClusterRole`, a CRD, a
  `ClusterIssuer`, or deploy outside `eurotransit`, no matter what a manifest says.
- The projects are created by `root-app` at **sync-wave `-2`**, before any Application
  references them (`argocd` -1, `platform` 0, `workloads` 1). `root-app` itself stays on
  `project: default` — it is the trusted seed that *creates* the projects, so it cannot depend
  on them.

## Alternatives considered

- **Keep everything on `default`.** Rejected — no blast-radius containment; contradicts the
  documented threat model.
- **One strict AppProject for all apps.** Rejected — the platform needs sweeping cluster-scoped
  rights, so a single project tight enough to constrain the app tier would have to whitelist
  almost everything for the platform anyway, defeating the point. Two tiers keep the app tier
  genuinely least-privilege while leaving the platform appropriately broad.
- **Per-Application projects (five+).** Rejected — boilerplate with little marginal gain over
  the two-tier split at this scale; the meaningful boundary is app-tier vs platform-tier.
- **Project-scoped RBAC instead of resource scoping.** Different concern (who can operate Argo,
  handled by SSO/RBAC in EM-39). AppProjects here are about what an *Application* may deploy.

## Consequences

**Easier / safer:**
- The app tier is contained to one namespace with no cluster-scoped power — a bad manifest there
  fails closed instead of touching `kube-system` or minting a ClusterRole.
- Source is pinned to the config repo for every app.
- Clear, self-documenting privilege tiers.

**Harder / risks:**
- **Whitelists must track reality.** If a leaf app later needs a new cluster-scoped resource,
  the `eurotransit` project must be widened or the app moved to `platform`. A too-tight project
  surfaces as a sync permission error (fails closed) — annoying but safe.
- **Live migration.** Changing an Application's `project` is safe **only** if the new project
  permits everything the app currently manages; the whitelists above were set from the live
  resource set, so no in-use kind is lost. Applied via the normal GitOps sync (projects at
  wave -2 exist before the repointed apps reconcile).

## Verification & ownership (agentic-coding policy)

- [ ] After sync, `kubectl -n argocd get appproject` shows `platform` and `eurotransit`; all
      Applications report Healthy with no "project not permitted" conditions.
- [ ] Negative test: a manifest adding a `ClusterRole` to the `eurotransit` app is **rejected**
      by the project (proves the app tier can't escalate).
- [ ] Confirm the three leaf apps still create their namespaced resources in `eurotransit`
      (CreateNamespace works via the `Namespace` cluster whitelist entry).

## References

- `bootstrap/apps/projects.yaml` — the two AppProjects.
- `CLAUDE.md` — agentic-coding threat model (blast radius, review gate).
- ADR 0007/0010 — the other blast-radius decisions (write-back token, ACR identity).
