# Runbook: Terraform state (Garage on the Mac Pro host)

Design: [ADR 0010](../decisions/0010-garage-host-s3.md). Endpoint: `https://s3.lab.macpro:3900`, bucket `tfstate`,
objects `host/terraform.tfstate` and `talos/terraform.tfstate`.

## Everyday

| Job | How |
|---|---|
| Run Terraform | Always through the Makefile (`make up/plan/destroy`) or `scripts/tf.sh <host\|talos> <args>`. Plain `terraform` works for reads, but skips the lock and the history |
| Deploy, upgrade, renew the S3 cert | `make garage` (idempotent; reissues the certificate with under 30 days left; restarts the containers only when their config changed) |
| Check | `make verify` section 8, or `ssh macpro 'cd homelab-garage && docker compose ps'` |
| Garage CLI | `ssh macpro 'cd homelab-garage && docker compose exec garage /garage status'` (also `bucket list`, `key list`, `layout show`) |
| Logs | `ssh macpro 'cd homelab-garage && docker compose logs --tail 50'`, or dozzle on the host (port 1001) |
| List state snapshots | `make state-history` |
| "another Terraform run holds .cache/terraform.lock" | Another `make`/`tf.sh` is running (maybe in the TUI). It waits up to 15 min; `fuser .cache/terraform.lock` shows who |

## One-time setup (done 2026-11-21)

1. `make garage`: secrets, certificate, containers, layout, buckets, keys, `.cache/garage/credentials`.
2. **AdGuard rewrite** (you, in the AdGuard UI): *Filters → DNS rewrites → Add*: domain `s3.lab.macpro`, answer
   `192.168.8.207`. The exact name wins over the `*.lab.macpro` wildcard. Check: `getent hosts s3.lab.macpro`.
3. `make state-migrate`: keeps an encrypted copy of each local state, runs `terraform init -migrate-state`, checks
   that resources and outputs in Garage are identical, removes the plaintext local files, then plans (expect no
   changes). Terraform writes the copy with a **new lineage and serial 1**, so the `…-pre-garage` snapshot needs
   `state push -force` if it's ever restored.
4. Commit `host/garage/secrets.enc.yaml`.

## Restore a state snapshot

After a bad apply or a damaged object. Snapshots are named `<time>-<sha>.tfstate.age`; the newest is last.

```sh
make state-history                                   # pick one
f=.cache/state-history/host/<snapshot>.tfstate.age
.tools/bin/age -d -i .cache/age/key.txt "$f" > /tmp/restore.tfstate   # plaintext: contains secrets
scripts/tf.sh host state push -force /tmp/restore.tfstate && rm /tmp/restore.tfstate
scripts/tf.sh host plan                              # check it matches reality
```

`-force` is needed when the snapshot's serial is lower than the current one, which is normal for a rollback.

## Rebuild Garage (host reinstalled, volumes lost)

1. `make garage`: the same keys come back from the SOPS file; the buckets are empty.
2. Push each stack's newest snapshot as above (host first, then talos).
3. `make verify`.

## When it's down

`make up`, `make verify`, `make start` and the TUI need the backend (they read node IPs from state). Check the
containers (`docker compose ps` above), then `make garage` to converge. Nothing in the cluster depends on
Garage until CNPG backups (milestone 5), and those just retry.
