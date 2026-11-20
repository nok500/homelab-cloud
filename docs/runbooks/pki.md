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

## Backup & restore

**What:** `.cache/ca/` (root key, intermediate key, all CA passwords, the provisioner key) and
`.cache/age/key.txt` (decrypts every `*.enc.yaml` in Git, including the OpenBao seed). Both are git-ignored
and exist only on voodoo. `.cache/ca` holds the root key *and* its password, so the backup is fully sensitive.

**Why it matters:** losing `.cache/age` means nothing encrypted in Git can be decrypted: a new PKI
(`make pki`), a new OpenBao seed, and re-trusting a new root on every machine. Losing only `.cache/ca` is
survivable until the intermediate needs re-signing (2031).

**Never** put the keys in Git, Outline or any wiki/chat, even private ones: those keep revision history,
index content, and are readable by every integration and API token.

### Back up

```sh
make pki-backup                          # asks for a passphrase twice; BACKUP_DIR=/path to write elsewhere
```

It writes `~/homelab-pki-<date>.tar.gz.age`: a tarball of `ca/` and `age/`, encrypted with
[age](https://age-encryption.org) using a passphrase (scrypt). It lists the archive by decrypting it again,
which proves the passphrase works.

| Keep | Where |
|---|---|
| the passphrase | password manager |
| the `.age` file | off voodoo, in one or two places (USB stick; password-manager file attachment). Without the passphrase it's useless to anyone |

Run it again whenever `.cache/ca` or `.cache/age` changes, which only happens with a new `make pki`.
The OpenBao unseal key and admin password live in the SOPS file in Git, so backing up the age key covers them.

### Restore (new workstation, or `.cache` lost)

```sh
cd ~/projects/lab/homelab-cloud           # fresh clone, then: make tools
mkdir -p .cache && .tools/bin/age -d ~/homelab-pki-<date>.tar.gz.age | tar -C .cache -xzf -
chmod -R go-rwx .cache/ca .cache/age
.tools/bin/step certificate fingerprint .cache/ca/root_ca.crt   # must be 20567e77…13c0d8 (top of this page)
make bao-password >/dev/null && echo "age key decrypts the OpenBao seed"
```

Then everything works as before: `make up` applies the seed, and trusted clients keep trusting the same root.

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
| Change a step-ca secret | They live in OpenBao `secret/step-ca`, seeded from `.cache/ca` by `make openbao-seed` ([secrets.md](secrets.md)) |
| Re-render `ca.json` / issuer after changing `scripts/pki-render.py` | `python3 scripts/pki-render.py`, then commit and push |
| Force a renewal | `kubectl -n gateway delete secret lab-wildcard-tls` (cert-manager re-issues within seconds) |
| Cert stuck not Ready | `kubectl -n gateway describe certificaterequest`; `kubectl -n step-issuer logs deploy/step-issuer`; `kubectl -n step-ca logs sts/step-ca` |
| New PKI (last resort) | `rm -rf .cache/ca` (keep `.cache/age`), then `make pki` (it also rebuilds the OpenBao seed), commit, push, rebuild, re-trust everywhere |
