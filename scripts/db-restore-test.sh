#!/usr/bin/env bash
# make db-restore-test: point-in-time restore of pg-demo from Garage into a new cluster (ADR 0011).
#   1. on pg-demo: a row 'before-backup', then an on-demand base backup (Backup, method plugin)
#   2. a row 'after-backup', note the target time T, then a row 'after-target'; switch WAL and wait until archived
#   3. a new cluster pg-demo-restore bootstraps from the object store, recovery target T
#   4. it must have 'before-backup' and 'after-backup' (base backup + WAL replay) and NOT 'after-target' (PITR)
#   5. the restore cluster is deleted again (KEEP=1 keeps it)
# The restore cluster doesn't archive WAL, so it never writes into pg-demo's backup path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"
NS=databases SRC=pg-demo DST=pg-demo-restore
say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
start=${SECONDS}

primary="$(kubectl -n "${NS}" get cluster "${SRC}" -o jsonpath='{.status.currentPrimary}')"
[[ -n "${primary}" ]] || { echo "no primary for ${SRC}: is the databases app healthy?" >&2; exit 1; }
sql() { kubectl -n "${NS}" exec "${primary}" -c postgres -- psql -d app -qAtX -c "$1"; }
image="$(kubectl -n "${NS}" get cluster "${SRC}" -o jsonpath='{.spec.imageName}')"
kubectl -n "${NS}" delete cluster "${DST}" --ignore-not-found --wait=true >/dev/null

say "1. ${SRC} (primary ${primary}): row 'before-backup', then a base backup"
sql "CREATE TABLE IF NOT EXISTS restore_test (id serial PRIMARY KEY, label text, at timestamptz DEFAULT clock_timestamp());
     TRUNCATE restore_test; INSERT INTO restore_test (label) VALUES ('before-backup');"
backup="${SRC}-restore-test-$(date +%s)"
kubectl -n "${NS}" apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${backup}
spec:
  cluster:
    name: ${SRC}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl -n "${NS}" wait "backup/${backup}" --for=jsonpath='{.status.phase}'=completed --timeout=600s >/dev/null
echo "   backup ${backup}: completed ($(kubectl -n "${NS}" get backup "${backup}" -o jsonpath='{.status.backupId}'))"

say "2. rows after the backup, around the recovery target"
sql "INSERT INTO restore_test (label) VALUES ('after-backup');"
sleep 2
target="$(sql "SELECT clock_timestamp()::text;")"
sleep 2
sql "INSERT INTO restore_test (label) VALUES ('after-target');"
wal="$(sql "SELECT pg_walfile_name(pg_switch_wal());")"
echo "   target time ${target}; waiting for WAL ${wal} to be archived"
for _ in $(seq 1 60); do
  archived="$(sql "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver;")"
  [[ -n "${archived}" && ! "${archived}" < "${wal}" ]] && break
  sleep 5
done
[[ -n "${archived}" && ! "${archived}" < "${wal}" ]] || { echo "WAL ${wal} not archived after 5 min (last: ${archived})" >&2; exit 1; }
echo "   archived up to ${archived}"

say "3. ${DST}: restore from Garage to ${target}"
kubectl -n "${NS}" apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DST}
spec:
  instances: 1
  imageName: ${image}
  storage:
    size: 2Gi
  resources:
    requests: {cpu: 50m, memory: 256Mi}
    limits: {memory: 512Mi}
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "${target}"
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: garage
          serverName: ${SRC}
EOF
kubectl -n "${NS}" wait "cluster/${DST}" --for=condition=Ready --timeout=900s >/dev/null
restored="$(kubectl -n "${NS}" exec "${DST}-1" -c postgres -- psql -d app -qAtX -c "SELECT string_agg(label, ',' ORDER BY id) FROM restore_test;")"
echo "   rows in ${DST}: ${restored}"

say "4. result"
if [[ "${restored}" == "before-backup,after-backup" ]]; then
  echo "   PASS: base backup + WAL replay up to the target, nothing after it ($(( (SECONDS - start) / 60 ))m$(( (SECONDS - start) % 60 ))s)"
  rc=0
else
  echo "   FAIL: expected 'before-backup,after-backup', got '${restored}'" >&2
  rc=1
fi
if [[ "${KEEP:-0}" != 1 ]]; then
  kubectl -n "${NS}" delete cluster "${DST}" --wait=false >/dev/null
  kubectl -n "${NS}" delete backup "${backup}" --wait=false >/dev/null
  echo "   cleaned up ${DST} and ${backup} (KEEP=1 keeps them)"
fi
exit "${rc}"
