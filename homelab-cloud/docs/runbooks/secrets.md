# Runbook: secrets (OpenBao + External Secrets)

Design: [ADR 0008](../decisions/0008-secrets-openbao.md). OpenBao is rebuilt empty with the lab, then it unseals
itself and seeds itself from `k8s/platform/openbao/seed.enc.yaml` (SOPS).

## Access

| | |
|---|---|
| UI | https://bao.lab.macpro (method **Username**) |
| User | `admin` |
| Password | `make bao-password` |
| CLI | `kubectl -n openbao exec -it openbao-0 -- sh`, then `bao login -method=userpass username=admin` |

## Check

```sh
make verify                                                     # section 7
kubectl -n openbao exec openbao-0 -- bao status                 # Initialized true, Sealed false, Seal Type static
kubectl get clustersecretstore openbao                          # READY True
kubectl get externalsecrets -A                                  # every STATUS SecretSynced
kubectl -n openbao logs openbao-0 | grep -i "initialize"        # self-init errors show here
```

## Common jobs

| Job | How |
|---|---|
| Let a new namespace read secrets | Add it to `conditions.namespaces` in `k8s/platform/secret-store/cluster-secret-store.yaml`; keep its paths under `secret/<namespace>` |
| Add a secret for an app | As admin, write `secret/<namespace>/<name>`, then add an `ExternalSecret` with `remoteRef.key: <namespace>/<name>`. If it must survive rebuilds, seed it: add it to `scripts/openbao-seed.sh` and an `initialize "seed"` request in `k8s/platform/openbao/values.yaml` |
| New seed value, lab already running | Self-init only runs on empty storage, so a running OpenBao never sees it. After `make openbao-seed`, also write the same value to its path as `admin` (UI, CLI or the HTTP API), or rebuild. Done this way for Keycloak's four values on 2026-11-23 ([ADR 0012](../decisions/0012-identity-keycloak.md)) |
| Change a seed value | `make openbao-seed` (keeps the unseal key and admin password), commit, push, `make secrets`. Self-init only reads it on empty storage, so a running OpenBao needs the value written by hand, or a rebuild |
| Force a re-sync | `kubectl -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite` |
| OpenBao sealed after a restart | `kubectl -n openbao logs openbao-0`: the static seal reads `/openbao/seed/unseal.key`, so check that the `openbao-seed` Secret exists (`make secrets`) |
| Self-init failed halfway | It runs only once per storage. Fix the config, then delete the PVC + pod (`kubectl -n openbao delete pvc data-openbao-0 && kubectl -n openbao delete pod openbao-0`) so it starts empty again |
