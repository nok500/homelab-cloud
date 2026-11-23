# 0010: Garage S3 on the Mac Pro host: Compose, TLS via the lab CA, local locking and state history

- Status: accepted
- Date: 2026-11-21
- Builds on: [ADR 0006](0006-storage-and-state.md) (state lives outside the lab, on the host)

## Decision

| Piece | Choice | Why |
|---|---|---|
| Garage | **v2.5.0** (2026-10-24), pinned by digest, single node (`replication_factor = 1`), LMDB with a metadata snapshot every 6 h | Small (about 13 MiB of RAM), S3-compatible, and the snapshot is the recovery path after an unclean host stop |
| How it runs | A **Docker Compose** project (`host/garage/compose.yaml`), `restart: unless-stopped`, deployed by `make garage` over SSH | Docker is already on the host and systemd-managed (enabled at boot), and your user is in the `docker` group: **no sudo, no unit file**. ADR 0006 said "Docker + systemd"; Docker's restart policy under the systemd-managed daemon gives that without a unit of our own. Not Terraform: the stack holding the state can't keep its own state in itself |
| TLS | **Caddy 2.11.9** in front, on `192.168.8.207:3900` only. Certificate for `s3.lab.macpro` + `192.168.8.207`, signed **offline** by the lab intermediate CA (ADR 0007), 1 year, renewed by `make garage` with under 30 days left | State holds secrets (Talos machine secrets, the OPNsense root password) and CNPG backups hold data, so neither should cross the LAN in clear. Terraform (Go) and the root trusted on voodoo verify it with no extra flags. step-ca isn't used: it lives inside the cluster this state builds |
| Name | `s3.lab.macpro` → `192.168.8.207`: an exact AdGuard rewrite, which wins over `*.lab.macpro` → the Gateway | Pods resolve it too (OPNsense forwards to AdGuard), which milestone 5 needs |
| Exposure | Only the S3 port is published, and only on the LAN address. Garage's admin API and RPC stay on the Compose network; the CLI runs through `docker compose exec` | Nothing to attack but S3 with SigV4 keys |
| Keys | One key per bucket (`tfstate`, `cnpg-backups`), read+write on its own bucket only (tested: the tfstate key gets 403 on `cnpg-backups`). Created with `garage key import` from `host/garage/secrets.enc.yaml` (SOPS) | A reinstalled Garage gets the same keys, so nothing downstream changes |

## What Garage can't do, and what replaces it

Both tested against v2.5.0 on 2026-11-21:

| Gap | Effect on Terraform | Replacement |
|---|---|---|
| **Conditional writes are ignored.** A second `PUT` with `If-None-Match: *` returned 200 and overwrote the first | `use_lockfile = true` doesn't lock: two runs both "acquired" it, and one failed to release it | `use_lockfile = false`, and `scripts/tf.sh` takes an **flock on voodoo** around every command that can touch state. All Terraform runs come from voodoo, through the Makefile (tested: a second run waited for the first) |
| **No object versioning** (`PutBucketVersioning` is missing) | No way back after a bad apply or a corrupted state object | `scripts/tf.sh` keeps an **age-encrypted copy of the state** in `.cache/state-history/<stack>/` after every state-changing command (the last 20, only when it changed). That's a second copy on a second machine too |

Re-test both on every Garage upgrade: if conditional writes start working, switch `use_lockfile` on and keep the flock.

## Consequences

- `make destroy` never touches Garage; the lab state survives every rebuild.
- If the Mac Pro is reinstalled: `make garage` (same keys, empty buckets), then push the latest snapshot from
  `.cache/state-history` back ([terraform-state.md](../runbooks/terraform-state.md)).
- `.cache/garage/credentials` (git-ignored, written by `make garage`) is the Terraform key; the backends read it as
  profile `tfstate` through a path relative to the stack, so always run Terraform with `-chdir` (the Makefile and
  scripts do).
- Read-only `terraform output` calls (verify, start/shutdown, TUI) need the backend too: Garage down means those
  scripts can't find the node IPs.

## Amendment (2026-11-22): Garage UI

[noooste/garage-ui](https://github.com/Noooste/garage-ui) **v0.14.0** (MIT, 2026-10-14, pinned by digest) runs as a
third service in the same Compose project, reached only through Caddy at **`https://s3.lab.macpro:3909`**: the
same name and certificate as S3, a second port, so no DNS change.

- It holds Garage's **admin token**, so whoever logs in can do anything, including deleting `tfstate`. Its own
  docs say its access control "is not a security boundary". So: its admin login only (user `admin`, a random
  password in `host/garage/secrets.enc.yaml`, `make garage-ui-password`); token login off (no pasting the admin
  token into a browser); no published port of its own; LAN address only; TLS from the lab CA.
- Tested locally before deploying: the API answers 401 without a login, a wrong password and token login get 401,
  and the admin login lists the buckets. `make garage` and `make verify` (section 8) repeat the login-wall check.
- Its session-signing key is generated on first start into the `ui-data` volume and survives restarts.
- **Stays on its own admin login, no Keycloak SSO (decided 2026-11-23).** The UI supports OIDC next to the admin
  login, but v0.14.0 fetches the issuer's discovery document once at startup and exits if that fails: with OIDC
  on, it would crash-loop whenever the lab (and Keycloak with it) is down or destroyed, taking the admin login
  along, which is exactly when a UI outside the lab is needed. The Mac Pro host also has no route into the VPC
  (`sso.lab.macpro` times out from it), and the UI has no CA setting. Revisit option: a second, SSO-only UI
  in the cluster next to Keycloak (Garage's admin API behind Caddy TLS, its own Garage admin token in OpenBao),
  this one staying as break-glass.
- `make garage` now restarts only the container whose own files changed. Adding the UI restarted Garage too:
  a few seconds without S3, which CNPG's archiving retries through.
