# Runbook: databases (CloudNativePG, backups to Garage)

Design: [ADR 0011](../decisions/0011-databases-cnpg.md). Namespace `databases`, backups in
`s3://cnpg-backups/lab/<cluster>/` on Garage ([terraform-state.md](terraform-state.md) for Garage itself).

## Check

```sh
make verify                                                   # section 9
kubectl -n databases get clusters,backups,scheduledbackups
kubectl -n databases get cluster pg-demo -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'
#   ContinuousArchiving=True means WAL reaches Garage
```

## Connect

```sh
kubectl -n databases exec -it "$(kubectl -n databases get cluster pg-demo -o jsonpath='{.status.currentPrimary}')" \
  -c postgres -- psql -d app
```

Apps use the services `pg-demo-rw` (primary), `pg-demo-ro` (replicas) and `pg-demo-r` (any) in `databases`, with
the generated Secret `pg-demo-app` (user, password, URI).

| Cluster | Used by | Credentials |
|---|---|---|
| `pg-demo` | backup/restore test only | CNPG-generated `pg-demo-app` |
| `keycloak-db` | Keycloak (`keycloak-db-rw.databases.svc.cluster.local`) | seeded: OpenBao `secret/databases/keycloak-db` = `secret/keycloak/db` ([ADR 0012](../decisions/0012-identity-keycloak.md)) |
| `harbor-db` | Harbor (`harbor-db-rw…`, database `registry`) | seeded: `secret/databases/harbor-db` = `secret/harbor/db` ([ADR 0013](../decisions/0013-registry-harbor.md)) |

## Back up and restore

| Job | How |
|---|---|
| Prove backup and restore work | `make db-restore-test`: a point-in-time restore into `pg-demo-restore`, checked row by row, then deleted (`KEEP=1` keeps it) |
| Backup now | Apply a `Backup` (`spec.cluster.name`, `method: plugin`, `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`), as `scripts/db-restore-test.sh` does |
| Restore a cluster | A new `Cluster` with `bootstrap.recovery.source` pointing at an `externalClusters` entry with the plugin and `parameters: {barmanObjectName: garage, serverName: <old cluster>}`, optionally `recoveryTarget.targetTime`. The script is the worked example |
| Replace a broken instance | `kubectl -n databases delete pod <instance>` and its PVC: CNPG re-clones it from the primary |

A restored cluster should not archive into the old cluster's path: leave out its `plugins` (as the test does), or
give it a new `serverName`.

## On rebuild

`make destroy` empties `s3://cnpg-backups/lab/`, and `make up` starts empty databases with a clean WAL archive.
Data doesn't survive a rebuild (decided, ADR 0011).

## When it's wrong

| Symptom | Look at |
|---|---|
| `ContinuousArchiving` False | `kubectl -n databases logs <instance> -c plugin-barman-cloud`. DNS (`s3.lab.macpro` from a pod, `make verify` section 2), the `garage-s3` Secret (ExternalSecret synced?), Garage up (`make verify` section 8) |
| "Expected empty archive" | The prefix still holds WAL from an earlier cluster with the same name: `scripts/garage-wipe.sh cnpg-backups lab/<cluster>/` (data loss for that cluster's backups) |
| Backup stuck in `running` | Plugin logs: `kubectl -n cnpg-system logs deploy/cnpg-barman-plugin-plugin-barman-cloud` |
| No pods, `cnpg.io/hibernation=True`, the databases app `Suspended` | Hibernated by `make shutdown` (its first step) and never woken, e.g. after an interrupted shutdown or a `make up` instead of `make start`: `kubectl -n databases annotate cluster --all cnpg.io/hibernation-` |
| Pod Pending | Both workers are needed (required anti-affinity); check node capacity in the TUI's NODES box |
