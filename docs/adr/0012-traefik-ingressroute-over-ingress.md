# ADR 0012 — Traefik `IngressRoute` over native `Ingress`

- **Status:** Accepted (team ratification 2026-07-17 — routes live behind TLS; canary TraefikService exercised in demo dry-runs)
- **Date:** 2026-07-09
- **Deciders:** _@vojtech-n (drafted, delivery), full team to ratify_
- **Context tags:** delivery, traefik, ingress, progressive-delivery
- **Supersedes / Superseded by:** —

---

## Context

North-south routing (the app at `eurotransit.vojtechn.dev`, the Argo CD UI at
`argocd.eurotransit.vojtechn.dev`) can be expressed two ways on Traefik:

- the **native** Kubernetes `networking.k8s.io/v1 Ingress`, or
- Traefik's own CRDs — `IngressRoute`, `Middleware`, `TraefikService`.

Two capstone requirements decide it:

1. **Per-route HTTP→HTTPS redirect** via a Traefik `Middleware` (EM-33) — a first-class,
   route-scoped object, not a global annotation.
2. **Canary progressive delivery** via a **`TraefikService`** weighted across a stable and a
   canary backend (Pillar D; delivery-owner canonical form). Native `Ingress` has **no**
   standard way to express weighted traffic splitting — it would need controller-specific
   annotations that don't compose with the redirect/middleware model.

This surfaced as an operator question: *"in k9s the Ingresses view is empty — why?"* — which is
a direct consequence of this choice and worth recording.

## Decision

**Use Traefik `IngressRoute` (+ `Middleware`, `TraefikService`) for all north-south routing;
do not use native `Ingress` objects.**

- App routes: `IngressRoute` on `websecure` with the cert-manager secret, plus a redirect
  `IngressRoute` on `web` using the `Middleware` (`deploy/charts/eurotransit/templates/`).
- Canary/blue-green: `TraefikService` weighted routing (`traefik-services.yaml`).
- Argo CD UI: the same pattern under `platform/argocd/`.
- **TLS certificates** are still standard `cert-manager` `Certificate` objects; only the
  *routing* layer is Traefik-native.

### Why `k9s` shows no Ingresses (operational note)

k9s's **Ingresses** view lists `networking.k8s.io/v1 Ingress` resources. We create **none** in
steady state — routing lives in `IngressRoute` (a `traefik.io` CRD), which k9s shows under its
**CRD** views, not under Ingresses. So an empty Ingresses list is **expected**, not a fault.

To see the real routing:
```bash
kubectl -n eurotransit get ingressroute,middleware,traefikservice
kubectl -n argocd     get ingressroute,middleware
```
The **one** exception: during a Let's Encrypt HTTP-01 challenge, cert-manager creates a
*temporary* native `Ingress` (`cm-acme-http-solver-*`) for `/.well-known/acme-challenge`. It
appears in the Ingresses view only while a cert is being issued, then disappears.

## Alternatives considered

- **Native `Ingress` + Traefik annotations.** Rejected — cannot express weighted canary in a
  standard way; the redirect/middleware and canary models don't compose cleanly through
  annotations. We'd fight the abstraction for both required features.
- **A service mesh (canary via mesh).** Rejected — Traefik is already the ingress; a mesh is
  far more machinery than a single-cluster capstone needs (also a standing invariant:
  `TraefikService` weights are the only canary mechanism — delivery-owner).

## Consequences

- **Easier:** redirect Middleware and weighted `TraefikService` canary are first-class; the app
  and the Argo UI share one routing pattern; TLS stays portable (cert-manager).
- **Harder / risks:**
  - **Portability.** Routing is tied to Traefik; moving to another ingress controller means
    rewriting `IngressRoute`/`TraefikService` as that controller's equivalent. Acceptable —
    Traefik is a fixed architecture constraint for this project.
  - **Discoverability.** Tools/dashboards that look for native `Ingress` (k9s Ingresses, some
    `kubectl` habits) show nothing — documented above so it isn't mistaken for a broken route.

## Verification & ownership (agentic-coding policy)

- [ ] `kubectl -n eurotransit get ingressroute` lists the app routes; `curl -I http://…` → 308
      redirect; `https://…` serves the trusted cert.
- [ ] The canary `TraefikService` shifts traffic by weight during a rollout (Pillar D demo).
- [ ] Team confirms no native `Ingress` is expected in steady state (only the ephemeral ACME
      solver during issuance).

## References

- `deploy/charts/eurotransit/templates/ingress.yaml`, `middleware.yaml`, `traefik-services.yaml`.
- `platform/argocd/ingressroute.yaml`, `middleware.yaml`.
- `docs/delivery/tls-issuance-runbook.md` — the ACME solver Ingress during issuance.
- `.agent/agents/delivery-owner.md` — canary via `TraefikService` (invariant #4).
