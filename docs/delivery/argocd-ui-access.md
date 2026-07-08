# EM-35 — Argo CD UI access (argocd.eurotransit.vojtechn.dev)

Exposes the Argo CD web UI through Traefik with a public HTTPS cert, instead of
`kubectl port-forward`. Mirrors the app's north-south pattern (Traefik terminates
TLS; cert-manager issues the cert; a Middleware redirects HTTP→HTTPS).

## Why it's split across three files (three separate concerns)

Argo CD here is installed by **Kustomize** (`bootstrap/install/`, pinned upstream
`install.yaml`), not the Helm chart — so there's no `server.ingress` values block
like lab04. Exposing the UI touches **three distinct concerns**; none replaces
another, and all three are GitOps-managed:

| Concern | File(s) | Reconciled by |
|---|---|---|
| **What Argo CD *is*** — the install + its config (`server.insecure: "true"`) | `bootstrap/install/` (incl. `patch-cmd-params.yaml`) | the **argocd self-management** Application (`bootstrap/apps/argocd.yaml`), which tracks `bootstrap/install` |
| **How you *reach* the UI** — Traefik route + TLS cert + HTTP→HTTPS redirect | `platform/argocd/` (`Certificate`, `IngressRoute`, `Middleware`) | the **platform** app-of-apps (directory recurse), wave 1 |
| **Making the install GitOps-managed** — self-management | `bootstrap/apps/argocd.yaml` | root-app / `aks-bootstrap` (wave -1) |

Why each is required (a common "can I delete this?" question):

- **`patch-cmd-params.yaml` (`server.insecure`)** — self-management changed *who
  applies* `bootstrap/install`, not *what's in it*. Without this, argocd-server
  serves its own TLS while Traefik also does TLS → **TLS-in-TLS, the UI breaks**.
- **`platform/argocd/`** — self-management manages the *install*; it creates
  nothing that routes external HTTPS to `argocd-server`. Delete it and Argo runs
  fine but is unreachable except via `port-forward`.

### Why they can't just be one file

The obvious "put it all in `bootstrap/install`" fails on **CRD ordering**:
`bootstrap/install` is also the **seed** — `just install-argocd` runs
`kubectl apply -k` on it *before* Traefik/cert-manager exist. If the `IngressRoute`/
`Certificate` lived there, that seed apply would fail on unknown CRDs. So the
ingress must be applied *after* the platform is up → `platform/argocd/` (wave 1,
`SkipDryRunOnMissingResource`). Config stays with the install (seed-safe); ingress
comes after the platform (CRD-safe); self-management sits on top.

> **Self-management note:** `just install-argocd` (Kustomize) is only the one-time
> *seed* — Argo CD can't deploy the first Argo CD from Git. The `argocd`
> Application then adopts `bootstrap/install` and reconciles it, so the version,
> `server.insecure`, RBAC, and CRDs are all Git-driven from then on. Argo's kustomize
> build fetches the pinned upstream `install.yaml` base, so the repo-server needs
> egress (fine on AKS). Changing `server.insecure` still needs a one-time
> argocd-server restart — Argo updates the ConfigMap but won't auto-restart the pod.

## Prerequisites

- **DNS:** `argocd.eurotransit.vojtechn.dev` must resolve to the Traefik LB IP —
  covered by a wildcard `*.eurotransit.vojtechn.dev` record, or a dedicated A/CNAME.
  `dig +short argocd.eurotransit.vojtechn.dev` should return the LB IP.
- Traefik + cert-manager Healthy (they are — EM-33/34).

## Rollout (on a cluster already running Argo)

Everything reaches the cluster via GitOps once merged to the tracked branch: the
`argocd` self-management Application reconciles `bootstrap/install` (the
`server.insecure` patch), and the platform app-of-apps reconciles
`platform/argocd/*`. The only manual step is the one-time argocd-server restart so
the new `server.insecure` value takes effect:

```bash
# 1. Let Argo apply the self-management app + platform ingress (from the branch),
#    then restart argocd-server once so server.insecure takes effect.
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status  deploy/argocd-server --timeout=120s

# 2. Confirm the reconcile:
kubectl -n argocd get application platform
kubectl -n argocd get certificate argocd-server-tls        # → Ready=True
kubectl -n argocd get ingressroute,middleware
```

On a fresh bootstrap the patch is baked into `just install-argocd`, so only DNS +
the platform sync are needed.

## Verify

```bash
# Trusted prod cert for the UI host (no -k):
echo | openssl s_client -connect argocd.eurotransit.vojtechn.dev:443 \
  -servername argocd.eurotransit.vojtechn.dev 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# HTTP → HTTPS redirect:
curl -sSI http://argocd.eurotransit.vojtechn.dev | head -1     # 308
```

Then browse **https://argocd.eurotransit.vojtechn.dev** (user `admin`). Password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

> Rotate/disable the initial admin password before the demo; the `just argocd-ui`
> port-forward recipe still works as a fallback if the ingress is down.
