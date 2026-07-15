# Sealed Secrets sealing-key disaster recovery

**Owner:** @vojtech-n (Delivery & Platform)
**Applies to:** the `sealed-secrets` controller (namespace `sealed-secrets`, deployment `sealed-secrets`)

## Why this runbook exists

Every `SealedSecret` in this repo is encrypted against the **controller's private
sealing key** — the one piece of state that *cannot* be GitOps-managed, because it
is the secret you would need to seal it with. It lives only as a `Secret` inside
the cluster.

On a **rebuilt cluster** the freshly installed controller generates a **new** key
pair. Every committed `SealedSecret` then fails to decrypt (`no key could decrypt
secret`), and the workloads that reference the unsealed Secrets stay stuck —
Argo CD cannot fix this, because Git only holds ciphertext for a key that no
longer exists.

Two ways out, in order of preference:

1. **Restore the backed-up key** (minutes, no re-sealing) — this runbook.
2. **Re-seal everything** against the new key and commit (fallback, see below).

This is also why `--scope strict` renames "breaking decryption" is a feature but
key loss is not: strict scope binds ciphertext to name+namespace; key loss
invalidates *all* ciphertext at once.

## Backup (run once after bootstrap, and after any key rotation)

```bash
just seal-key-backup                  # writes to ~/eurotransit-sealed-secrets-key-<date>.yaml
just seal-key-backup /path/to/backup  # explicit path (must be OUTSIDE the repo)
```

The recipe exports every Secret labelled `sealedsecrets.bitnami.com/sealed-secrets-key`
(the controller keeps old keys around for decryption; back them **all** up, not
just the active one).

**Storage rules:**

- Put the file in the team vault (password manager or Azure Key Vault as a
  secret blob). It is a **plaintext private key** — treat it like the kubeconfig.
- **Never commit it.** The recipe refuses to write inside the repo, and the CI
  gitleaks gate + pre-commit hook are the backstop, but the vault is the real
  control.
- Re-run the backup if the controller ever rotates keys (default rotation is
  every 30 days — new key added, old keys kept; the backup should follow).

## Restore (fresh cluster, before workloads need their secrets)

Ordering: the platform app (wave 0) installs the controller; the workloads app
(wave 1) applies the `SealedSecret`s. Restore the key as soon as the
`sealed-secrets` namespace exists — ideally right after `just install-argocd` +
root-app, while wave 0 is still converging:

```bash
just seal-key-restore ~/eurotransit-sealed-secrets-key-<date>.yaml
```

Which does:

```bash
kubectl apply -f <backup>.yaml                                    # re-create the key Secret(s)
kubectl rollout restart deployment sealed-secrets -n sealed-secrets  # controller re-reads keys
kubectl rollout status  deployment sealed-secrets -n sealed-secrets
```

The restarted controller loads **all** key Secrets in its namespace and
re-processes existing `SealedSecret`s, so anything that failed to unseal before
the restore converges on its own. If the cluster's auto-generated key had
already sealed something new, leave that Secret in place — the controller
decrypts with every key it holds and encrypts with the newest.

**Verify:**

```bash
kubectl get sealedsecrets -n eurotransit          # status should show Synced=True
kubectl get secrets -n eurotransit                # unsealed Secrets present
```

## Fallback: no backup exists

If the old key is gone for good, the ciphertext in Git is dead. Re-seal from the
plaintext sources (each secret's `.env.<name>` file or the value's system of
record) against the new cluster's certificate:

```bash
just seal <name> eurotransit        # per secret, then commit the new SealedSecrets
```

One PR, one commit, Argo CD reconciles. Budget roughly an hour and access to
every plaintext source — which is exactly the cost the backup exists to avoid.

## What this is NOT

- Not a rotation procedure — the controller rotates on its own; this runbook
  only ensures rotated keys are *backed up*.
- Not for the CloudNativePG or Strimzi secrets — those are operator-generated
  per cluster and regenerate correctly on a rebuild; nothing to back up.
