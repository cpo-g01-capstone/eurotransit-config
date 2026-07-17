# ADR 0028 — Helm for application packaging; Kustomize confined to the Argo CD bootstrap

- **Status:** Accepted (team ratification 2026-07-17 — split in use: Helm for apps, Kustomize seed for bootstrap)
- **Date:** 2026-07-16
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** delivery, helm, kustomize, gitops
- **Supersedes / Superseded by:** —

---

## Context

Argo CD can render several source formats, and this repository uses three: Helm for the
EuroTransit services, Kustomize for the Argo CD installation, and plain YAML directories
for Kafka/PostgreSQL/app-of-apps (see the README "How manifests are rendered" table).
Two questions kept resurfacing and deserve a recorded answer rather than folklore:

1. **Why Helm and not Kustomize for the application chart?** Kustomize is the "simpler"
   tool on paper — plain YAML, no Go templating (which editors and validators choke on),
   native in `kubectl -k` and Argo CD, and overlays are a natural fit for the
   baseline-vs-AKS split currently handled by `global.imageRegistry`.
2. **Why does a Kustomize island exist at all** (`bootstrap/install/`), and should it be
   removed for tooling uniformity?

This decision was formalized retroactively: the split has been in place since the
bootstrap work (EM-35/EM-39), and the README already states "Kustomize is intentionally
limited to the Argo CD installation" — but the reasoning lived nowhere citable.

## Decision

**Helm packages the five EuroTransit services** (`deploy/charts/eurotransit/`, one chart —
ADR 0008). **Kustomize is used in exactly one place** — `bootstrap/install/` — to install
Argo CD itself, and is not extended beyond it. Neither tool replaces the other.

Why Helm wins for the application tier:

- **Five near-identical Spring services.** Helm templates + `_helpers.tpl` express the
  shared shape (probes, lifecycle, SASL env, DB env contract) once and stamp it five
  times, parameterized by `values.yaml`. In Kustomize the equivalent is either five
  copied bases or a deep patch pyramid — more YAML, not less, and drift between copies
  is exactly the failure mode helpers exist to prevent (agent-log Cases 13/22 were fixed
  in *one* helper, not five files).
- **The GitOps write-back loop is values-driven.** CI bumps `<service>.image.tag` in one
  `values.yaml` with one `yq` expression (ADR 0007). Kustomize's `images:` transformer
  could do this too, but migrating buys nothing and rewires a working, documented loop.
- **The environment split is one scalar.** Baseline vs AKS differs by
  `global.imageRegistry` and pull secrets — a values override, not an overlay tree.
  Kustomize's overlay strength only pays off with a real environment matrix, which
  ADR 0009 (one stack, no staging) deliberately rules out.
- **Conditional resources** (canary/blue-green tracks, HPA-vs-replicas per ADR 0025)
  are `{{ if }}` blocks; Kustomize needs component gymnastics for the same effect.

Why Kustomize stays for the Argo CD bootstrap:

- The upstream Argo CD **install manifest is the artifact** — a pinned, non-templated
  YAML at a release tag. Kustomize's remote-resource + strategic-merge-patch model is
  the standard, minimal way to apply local deltas (`server.insecure`, Dex SSO, RBAC,
  the `argocd-secret` patch-mode annotations from ADR 0015) on top of it.
- The same Kustomization serves both the one-time imperative seed
  (`just install-argocd` → `kubectl apply -k`) and the self-management Application
  (`bootstrap/apps/argocd.yaml`), so seed and reconciled state cannot diverge.

## Alternatives considered

- **Kustomize base + overlays for the application tier.** Rejected: five homogeneous
  services make templating (DRY via helpers) strictly cheaper than patching; the
  overlay use case (env matrix) does not exist under ADR 0009. The one real Helm cost —
  templates are not valid standalone YAML, so editors/validators need special handling —
  is mitigated tool-side (`.vscode/` Helm language mapping, `just helm-verify` +
  `just helm-schema` validate the *rendered* output).
- **Replace `bootstrap/install/` with the community Argo CD Helm chart**
  (`argo/argo-cd`) for tooling uniformity. Rejected: the chart produces differently
  named/labelled resources than the upstream manifest, so the live, self-managing
  Argo CD would have to adopt a foreign resource tree — a high-risk migration
  (ownership churn, `argocd-secret` exposure re-running the lab04 wipe incident, CRD
  ServerSideApply edge cases) for zero functional gain. Estimated 1–2 days plus real
  outage risk on the control plane that deploys everything else.
- **Vendor the rendered Argo CD manifest as plain YAML** (`kustomize build` output
  committed). Rejected: removes the tool but keeps its output — a ~20k-line generated
  file where the four patches are no longer visible as deltas, making version bumps
  and review effectively opaque.
- **Kustomize tidy of `platform/argocd/`.** Already considered and deferred in
  DELIVERY.md — cosmetic, and carving it out of the directory-recurse `platform` app
  risks a transient prune of the Argo UI route and a Let's Encrypt re-issue.

## Consequences

**Easier:**
- One packaging idiom per tier, each doing what it is best at; the README table stays
  truthful ("Kustomize is intentionally limited to the Argo CD installation").
- Shared service config keeps a single point of change (helpers), preserving the
  one-fix-fixes-all property relied on in past incident fixes.
- Argo CD version bumps remain a one-line `targetRevision` edit with patches intact.

**Harder / risks:**
- Contributors must know two tools (Helm templating *and* Kustomize patches), though
  the Kustomize surface is four small patch files that rarely change.
- Helm templates remain invalid standalone YAML; new contributors must install the
  recommended VS Code extensions (`.vscode/extensions.json`) or live with false errors.
- Revisit **only if** a real environment matrix appears (staging/prod overlays) — and
  even then, prefer Argo CD's Helm-then-Kustomize layering over migrating the chart.

## Verification & ownership (agentic-coding policy)

- [ ] Team confirms the two-tool split (Helm apps / Kustomize bootstrap) and that
      neither tier should migrate to the other's tool.
- [ ] Team confirms the effort/risk estimate for removing `bootstrap/install/`
      Kustomize is not worth paying before the demo.
- [ ] README "How manifests are rendered" table cross-checked against this ADR.

## References

- ADR 0008 — single Helm chart for all five services.
- ADR 0009 — one stack, no staging (removes the overlay use case).
- ADR 0015 — the `argocd-secret` patch-mode annotations that live in the Kustomize patch.
- `bootstrap/install/kustomization.yaml` — the entire Kustomize footprint.
- `bootstrap/apps/argocd.yaml` — self-management Application rendering the same path.
- README.md § "How manifests are rendered" — the per-tier rendering table.
