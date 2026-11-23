# 0011: Databases ("RDS"): CloudNativePG, Barman Cloud plugin backups to Garage, fresh per rebuild

- Status: accepted
- Date: 2026-11-21

## Decision

| Piece | Choice | Why |
|---|---|---|
| Operator | **CloudNativePG 1.30.2** (chart 0.29.2), cluster-wide, in `cnpg-system` | Only 4 days old when pinned, against the two-week rule: it fixes Go vulnerabilities (golang.org/x/net) and its default PostgreSQL image fixes several CVEs |
| PostgreSQL | `ghcr.io/cloudnative-pg/postgresql:18.7-system-trixie`, pinned by digest | The operator's new default operand image (the one with the CVE fixes) |
| Backups | **Barman Cloud plugin v0.15.1** (chart 0.8.1) | CNPG's in-tree `barmanObjectStore` is announced for removal in 1.32. v0.16.0 is under two weeks old and has no security fixes. The plugin needs CNPG ≥ 1.30 and cert-manager, both in place |
| Target | One `ObjectStore` `garage` per database namespace: `s3://cnpg-backups/lab/<cluster>/` on `https://s3.lab.macpro:3900` | Garage on the host, outside the lab ([ADR 0010](0010-garage-host-s3.md)). Base backups gzip, WAL zstd, 7-day retention |
| Credentials | The `cnpg-backups` Garage key, seeded into OpenBao `secret/databases/garage-s3`, delivered by External Secrets (namespace `databases` on the store's allow-list) | Same path as every other secret ([ADR 0008](0008-secrets-openbao.md)). The key can only touch its own bucket |
| TLS | `endpointCA` = the lab root (`k8s/platform/databases/lab-root-ca.crt`, written by `scripts/pki-render.py`) | Garage's certificate is signed by the lab CA |
| Where | Namespace **`databases`**, one per lab: every platform database (Keycloak, Harbor) lives here, apps connect across namespaces | Like RDS as its own service, outside the app's account |
| Shape | `pg-demo`: 2 instances (primary + streaming replica), **required** anti-affinity (one per worker), local-path volumes, `archive_timeout = 5min`, daily base backup at 03:00 plus one at creation | Durability one level up from node-local storage ([ADR 0006](0006-storage-and-state.md)): a lost worker is a failover, a lost cluster is a restore |

## Lifecycle: fresh databases on every rebuild (decided)

`make destroy` empties `s3://cnpg-backups/lab/` (`scripts/garage-wipe.sh`), so each `make up` starts with empty
databases and an empty WAL archive. Same lifecycle as OpenBao: what matters long-term comes from code (Keycloak's
realm is Terraform, [ADR 0012](0012-identity-keycloak.md)). It also avoids CNPG's refusal to archive into a path that already holds another
cluster's WAL.

Backups and point-in-time restore protect data **while the lab runs**: node loss, a bad migration, a dropped table.

Rejected: restoring each database from its last backup on `make up` (data survives rebuilds, RDS-snapshot style).
Bootstrap would have to choose initdb or recovery, and each restored generation needs a new archive path.
Revisit if Harbor's data must survive rebuilds (milestone 7).

## Restore test

`make db-restore-test`:
1. On `pg-demo`, write row 1, take a base backup, write row 2, note the time T, then write row 3.
2. Restore into a new cluster `pg-demo-restore` from Garage with recovery target T.
3. It must hold rows 1 and 2 (base backup plus WAL replay) and not row 3 (point in time).
4. The restore cluster is deleted again.

## Consequences

- The VPC had to learn to resolve `s3.lab.macpro` first ([ADR 0004](0004-lab-dns.md) amendment).
- Keycloak (milestone 6) and Harbor (milestone 7) get their databases as new `Cluster` resources in `databases`.
- Memory: about 256 MiB requested per instance, plus a 64 MiB sidecar each, on 4 GiB workers.
