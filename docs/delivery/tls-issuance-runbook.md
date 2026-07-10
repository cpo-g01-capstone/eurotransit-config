# EM-34 — TLS issuance runbook (cert-manager + Let's Encrypt)

How to bring up and verify public TLS for **eurotransit.vojtechn.dev**, and how to
promote from the Let's Encrypt **staging** issuer to **prod**. The chart wiring
already exists (EM-33); this is the operational half that only runs against a live
AKS cluster with the DNS record in place.

## Preconditions

- **DNS:** `eurotransit.vojtechn.dev` resolves to the Traefik LoadBalancer public IP
  (CNAME to `eurotransit-g01.<region>.cloudapp.azure.com`, or an A record to the LB IP).
  Verify: `dig +short eurotransit.vojtechn.dev` returns the LB IP.
- **Platform Synced/Healthy:** `cert-manager` (operator + `letsencrypt-staging` /
  `letsencrypt-prod` ClusterIssuers) and `traefik` Applications are Healthy in Argo CD.
- **App values applied:** the `eurotransit` Application renders `values.yaml`
  (`ingress.tls: true`, `ingress.host: eurotransit.vojtechn.dev`,
  `ingress.certIssuer` — iterate on `letsencrypt-staging` first, then prod; see below).

## What the chart renders (the moving parts)

| Object | Name | Role |
|---|---|---|
| `Certificate` (cert-manager) | `eurotransit-tls` | requests a cert for the host from `ingress.certIssuer` |
| `Secret` | `eurotransit-tls` | populated by cert-manager once issued; referenced by the IngressRoute TLS block |
| `IngressRoute` | `eurotransit` | app routes on `websecure`, `tls.secretName: eurotransit-tls` |
| `IngressRoute` | `eurotransit-redirect` | `web` → HTTPS 301 via the `eurotransit-redirect-https` Middleware |
| `ClusterIssuer` | `letsencrypt-staging` / `-prod` | ACME account + HTTP-01 solver on `ingressClassName: traefik` |

## 1. Verify on STAGING first

Staging has high rate limits, so it's safe to iterate. The cert will be **untrusted**
(browser warning) — that's expected; we only want to prove the HTTP-01 flow end to end.

```bash
# Certificate should progress to Ready=True
kubectl -n eurotransit get certificate eurotransit-tls
kubectl -n eurotransit describe certificate eurotransit-tls        # Events show the flow

# Follow the ACME objects cert-manager creates during the challenge
kubectl -n eurotransit get certificaterequest,order,challenge
# A stuck challenge usually means DNS or the HTTP-01 path isn't reachable:
kubectl -n eurotransit describe challenge <name>                   # look at Reason/State

# The temporary solver Ingress cert-manager creates for /.well-known/acme-challenge
kubectl -n eurotransit get ingress                                 # cm-acme-http-solver-*
```

Once `Certificate` is `Ready=True`, the `eurotransit-tls` secret is populated:

```bash
kubectl -n eurotransit get secret eurotransit-tls
# Inspect the issuer on the served cert (expect "(STAGING) Let's Encrypt"):
echo | openssl s_client -connect eurotransit.vojtechn.dev:443 \
  -servername eurotransit.vojtechn.dev 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates

# Redirect works (HTTP → 301 → HTTPS). -k tolerates the untrusted staging cert:
curl -sSI  http://eurotransit.vojtechn.dev/api/catalog        | head -1   # 301
curl -sSIk https://eurotransit.vojtechn.dev/api/catalog       | head -1   # 200/4xx from the app
```

## 2. Promote to PROD

Only after staging has issued for this exact host. Flip the issuer in the overlay —
this is a **reviewed Git commit**, not a live edit (Argo self-heal would revert a live edit):

```yaml
# deploy/charts/eurotransit/values.yaml
ingress:
  certIssuer: "letsencrypt-prod"     # was: letsencrypt-staging
```

Commit + push; Argo CD reconciles. cert-manager sees the `issuerRef` change and
re-issues from prod. Force a clean re-issue if it lingers on the staging secret:

```bash
# Optional: delete the staging-issued secret so cert-manager requests a fresh prod cert
kubectl -n eurotransit delete secret eurotransit-tls
kubectl -n eurotransit get certificate eurotransit-tls -w        # back to Ready=True
```

Verify the served cert is now **trusted** (note: no `-k`):

```bash
echo | openssl s_client -connect eurotransit.vojtechn.dev:443 \
  -servername eurotransit.vojtechn.dev 2>/dev/null \
  | openssl x509 -noout -issuer -dates                            # "Let's Encrypt", not STAGING
curl -sSI https://eurotransit.vojtechn.dev/api/catalog | head -1  # 200/4xx, no TLS warning
```

## Rate limits & gotchas

- **Prod rate limit:** 5 duplicate certs / week per hostname. Don't loop prod re-issues;
  that's why staging goes first.
- **HTTP-01 needs :80 reachable** at the challenge path. The per-route HTTPS redirect
  (EM-33) is on the app router only; cert-manager's solver Ingress is separate and is
  **not** redirected, so the challenge still succeeds. If a challenge hangs, first check
  `dig` and that the LB answers on :80.
- **`ingressClassName: traefik`** on the solver must match the Traefik chart's pinned
  IngressClass name — it does (set in `platform/traefik/traefik.yaml`).
- Staging and prod use **separate ACME account keys**
  (`letsencrypt-staging-account-key` / `letsencrypt-prod-account-key`) — expected.

## Record the result

Capture for the demo/DoD: the `Certificate` Ready event, the `openssl` issuer line
(staging → prod), and a clean `https://eurotransit.vojtechn.dev` load. This is the
Pillar D "public HTTPS north-south entrypoint" evidence.
