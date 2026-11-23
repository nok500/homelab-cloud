# 0007: Private PKI ("ACM"): persistent, name-constrained root; step-ca + cert-manager; SOPS for bootstrap secrets

- Status: accepted
- Date: 2026-11-20

## Decision

| Piece | Choice | Why |
|---|---|---|
| Root CA | ECDSA P-256, 10 y, **name-constrained** (critical) to `lab.macpro` + `cluster.local`; key **offline** in `.cache/ca` | Trusted once per machine and survives `make destroy && make up`. The constraint limits what a leaked lab CA could do: even trusted system-wide, it can't vouch for any other domain |
| Intermediate CA | 5 y, the key step-ca signs with | Losing it means re-issuing from the offline root, with no re-trust needed |
| CA server | **step-ca** 0.30.2 (chart `step-certificates` 1.30.1), `existingSecrets` mode | Real CA with ACME/JWK/OIDC provisioners. The chart can't mix `existingSecrets` with `inject`, so `ca.json` and the certs are plain ConfigMaps in Git (`k8s/platform/step-ca/config`) |
| Issuing | **cert-manager** v1.21.3 + **step-issuer** 0.11.0 (chart 1.11.0), JWK provisioner | Wildcards need DNS-01 under ACME, and the lab DNS (AdGuard rewrite) has no API. step-issuer signs CSRs directly, wildcards included |
| Certificate | One `*.lab.macpro` wildcard on the Gateway, 90 d, renewed at 60 d, key rotated each renewal | Like one ACM cert on an ALB. Every new service only needs an HTTPRoute |
| Bootstrap secrets | **SOPS + age** (`*.enc.yaml`, only `data`/`stringData` encrypted), applied by `scripts/apply-bootstrap-secrets.sh` | As the brief asks: no plaintext secrets in Git. The age key is git-ignored. Since ADR 0008 the only SOPS file is the OpenBao seed; step-ca's secrets come from OpenBao |

## Where things live

| What | Where | Secret? |
|---|---|---|
| Root key, all passwords, provisioner private JWK | `.cache/ca/` (git-ignored, back it up) | yes: never leaves voodoo |
| age private key | `.cache/age/key.txt` (git-ignored, back it up) | yes |
| Intermediate key, CA password, provisioner password | OpenBao `secret/step-ca`, seeded from `k8s/platform/openbao/seed.enc.yaml` and synced by External Secrets ([ADR 0008](0008-secrets-openbao.md)) | encrypted |
| `ca.json` (includes the provisioner key *encrypted with its password*: step-ca serves it to clients by design), certs | `k8s/platform/step-ca/config/` | no |
| StepClusterIssuer (root bundle, provisioner kid) | `k8s/platform/certificates/step-cluster-issuer.yaml` | no |

`make pki` runs once (`scripts/pki-init.sh`, which refuses to overwrite). `scripts/pki-render.py` regenerates
the public files from `.cache/ca` without touching any key.

## Consequences

- The name constraint applies to the lab's own certificates too: every SAN must be under `lab.macpro` or
  `cluster.local`. Short service names like `step-ca.step-ca.svc` are rejected; step-ca even refuses to start
  (`DNS name "step-ca.step-ca.svc" is not permitted by any constraint`). Use the FQDN `*.svc.cluster.local`.

- TLS terminates at the Gateway. Backends stay plain HTTP inside the cluster for now (Argo CD `server.insecure`).
- Port 80 only redirects to 443. Every route attaches to the `https` listener.
- Clients must trust the root: `make trust-root` on voodoo (p11-kit system store). Browsers with their own store
  (Firefox) need it imported or `security.enterprise_roots.enabled`.
- Losing `.cache/age` means the encrypted secrets can't be decrypted: re-run `make pki` and re-trust a new root.
  Losing only `.cache/ca` is survivable until the intermediate needs re-signing.
