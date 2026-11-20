# 0008: Secrets ("Secrets Manager / KMS"): OpenBao, self-initialized and seeded on every rebuild; External Secrets

- Status: accepted
- Date: 2026-11-20

## Decision

| Piece | Choice | Why |
|---|---|---|
| Secrets store | **OpenBao 2.7.3** (chart 0.30.8), one standalone instance, pebbledb on a local-path volume | Open-source Vault fork (MPL). One replica fits 4 GiB workers; data loss on a node is covered by the next point |
| Lifecycle | **Regenerate + seed**: empty on every `make destroy && make up` | No restore path to maintain. Values that come from outside (the step-ca intermediate key, passwords) are seeded from SOPS. Generated app credentials are recreated, which is fine because their apps' data is rebuilt too |
| Unseal | `seal "static"`: a 32-byte key from the SOPS seed, mounted from the `openbao-seed` Secret | Auto-unseal with no KMS available. OpenBao's own docs say it's only appropriate when another trust source already exists. Here that's the age key, which already protects everything else |
| Configuration | **Declarative self-initialization** (`initialize` blocks in the server config): KV v2 at `secret/`, an `admin` userpass login, Kubernetes auth plus the `external-secrets` role/policy, and seeding `secret/step-ca` from the mounted files | No init Job and no root token: self-init revokes it after use. Tested locally in Docker against 2.7.3 before deploying |
| Audit | Declarative `audit "file" "stdout"` | Creating audit devices through the API is blocked by default; self-init failed until this moved to config |
| Sync to Kubernetes | **External Secrets Operator 2.14.0**, one `ClusterSecretStore` `openbao` | The standard way to get secrets into Kubernetes Secrets. Apps never talk to OpenBao directly |
| Bootstrap secret | **One** SOPS file: `k8s/platform/openbao/seed.enc.yaml` (`scripts/openbao-seed.sh`) | It replaces the step-ca SOPS file from ADR 0007. SOPS now only carries what OpenBao needs to exist |

**Version note:** 2.7.3 was one day old when it was pinned, against the usual "two weeks old" rule, because it fixes
GHSA-fgmw-h9wp-wc7g and GHSA-h8fh-pmch-cjww.

## Access control: who can read what

- ESO authenticates to OpenBao as its own service account (role `external-secrets`). It can **read** `secret/*` and
  **write** only `secret/generated/*`, for PushSecret-generated credentials in later milestones.
- **Who may use the store** is the `conditions.namespaces` allow-list on the `ClusterSecretStore`, kept in Git
  (currently `step-ca`). Paths are per namespace (`secret/<namespace>…`).
- Trade-off: per-namespace OpenBao roles, the closest thing to IRSA, would be stricter. But self-init runs once
  per rebuild, so each new namespace would need a config change plus a rebuild. Kyverno (Phase 5) enforces the
  key prefix per namespace instead.

## The exception: Argo CD's repo credential

The read-only deploy key stays a bootstrap secret, created by `scripts/bootstrap-cluster.sh`. The GitOps engine
needs it before it can deploy OpenBao, so it can't come from OpenBao, much as EKS's bootstrap credentials sit
outside Secrets Manager.

## Consequences

- OpenBao admin: `https://bao.lab.macpro`, method *Username*, user `admin`, password from `make bao-password`.
- A new seeded value means changing `openbao-seed.sh` and the self-init config, then a rebuild (or writing it
  once by hand as admin). Self-init never runs again on existing storage.
- No recovery keys are generated (static seal + self-init). The unseal key in SOPS is the recovery story.
