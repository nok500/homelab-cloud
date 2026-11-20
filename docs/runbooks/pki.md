# Runbook: lab PKI (step-ca, cert-manager, trust)

Design: [ADR 0007](../decisions/0007-private-pki.md). Root: **homelab-cloud Root CA**, valid until 2036-11-17,
SHA-256 fingerprint `20567e77050d19c62d8c88a70a43b286bfe6a83a00fe073f75cd7af01513c0d8`.

## Trust the root (once per machine)

```sh
make trust-root                                         # voodoo (Arch): p11-kit system store, sudo
```

| Client | How |
|---|---|
| Arch / Fedora | `sudo trust anchor --store k8s/platform/step-ca/config/root_ca.crt` |
| Debian / Ubuntu | copy it to `/usr/local/share/ca-certificates/homelab-cloud.crt`, then `sudo update-ca-certificates` |
| Firefox | Settings → Certificates → Import, or `about:config` → `security.enterprise_roots.enabled = true` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root_ca.crt` |

Before trusting it anywhere, check the fingerprint: `step certificate fingerprint k8s/platform/step-ca/config/root_ca.crt`.
The root is name-constrained to `lab.macpro` and `cluster.local`, so trusting it doesn't let it vouch for any other site.

## Back up (once, and keep it safe)

`.cache/ca/` (root key + passwords) and `.cache/age/key.txt`. Both are git-ignored. Without the age key, the
encrypted secrets in Git are unreadable, and the only way out is a new PKI plus re-trusting it everywhere.

## Check

```sh
make verify                                             # section 5: issuer, certificate, redirect, chain, trust
kubectl get stepclusterissuer step-ca                   # READY True
kubectl -n gateway get certificate lab-wildcard         # READY True, renews 30 d before expiry
openssl s_client -connect 10.10.1.200:443 -servername argocd.lab.macpro </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

## Common jobs

| Job | How |
|---|---|
| Edit a bootstrap secret | `SOPS_AGE_KEY_FILE=.cache/age/key.txt .tools/bin/sops k8s/platform/step-ca/secrets.enc.yaml`, then `make secrets` |
| Re-render `ca.json` / issuer after changing `scripts/pki-render.py` | `python3 scripts/pki-render.py`, then commit and push |
| Force a renewal | `kubectl -n gateway delete secret lab-wildcard-tls` (cert-manager re-issues within seconds) |
| Cert stuck not Ready | `kubectl -n gateway describe certificaterequest`; `kubectl -n step-issuer logs deploy/step-issuer`; `kubectl -n step-ca logs sts/step-ca` |
| New PKI (last resort) | `rm -rf .cache/ca` (keep `.cache/age`), then `make pki`, commit, push, `make secrets`, re-trust everywhere |
