# Runbook: registry (Harbor)

Design: [ADR 0013](../decisions/0013-registry-harbor.md). Harbor at **https://registry.lab.macpro**: layers on Garage
(`s3://harbor/lab/`), database `harbor-db` in `databases`, login via Keycloak, Trivy scanning.

## Access

| | |
|---|---|
| UI | https://registry.lab.macpro → **LOGIN VIA OIDC PROVIDER**, user `labadmin` (group `harbor-admins` = system admin) |
| CLI / break-glass | user `admin`, password from `make logins` (local accounts other than `admin` don't exist in OIDC mode) |
| From voodoo | `docker login registry.lab.macpro` (voodoo trusts the lab root: `make trust-root`) or `crane auth login` |
| From pods | `registry.lab.macpro/<project>/<image>:<tag>`; public projects (`library`) need no pull secret |

## Check

```sh
make verify                                                     # section 11: health, OIDC, push, scan, pod pull
kubectl -n harbor get pods
curl -s https://registry.lab.macpro/api/v2.0/health | python3 -m json.tool
kubectl -n databases get cluster harbor-db
```

## Common jobs

| Job | How |
|---|---|
| Push an image | `crane copy <src> registry.lab.macpro/library/<name>:<tag>` (after `crane auth login`), or `docker push` |
| See a scan | UI → Projects → library → the repository → the artifact, or `GET /api/v2.0/projects/library/repositories/<repo>/artifacts/<tag>?with_scan_overview=true` |
| Make someone an admin | Add them to `harbor-admins` in `terraform/identity`, then `make identity`; they log in once (auto-onboarding) |
| Change an auth setting | The OIDC JSON in `k8s/platform/harbor/secrets/external-secrets.yaml`; core re-applies it at start (`kubectl -n harbor rollout restart deploy/harbor-core`). Settings in it are read-only in the UI |
| Rotate a Harbor secret | Delete its key from the seed, `make openbao-seed`, write the new value to its `secret/harbor/*` path, delete the target Secret (ESO recreates it), restart Harbor. The token key pair and htpasswd line regenerate as pairs |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `x509: certificate signed by unknown authority` pushing from a laptop | That machine doesn't trust the lab root: `make trust-root` (voodoo), [pki.md](pki.md) for others |
| Pod `ImagePullBackOff` with an x509 error | The node lacks the `RegistryTLSConfig` (`talosctl -n <node> get registryconfigs -o yaml`, under `spec.tls`); `scripts/tf.sh talos apply` |
| Registry 500s, logs mention S3 | Garage key or reachability: the `harbor-s3` Secret synced? `make verify` section 8; `kubectl -n harbor logs deploy/harbor-registry -c registry` |
| Login loops or `invalid_client` | Client secret differs between Keycloak and Harbor: OpenBao `secret/harbor/oidc` vs the seed, then `make identity` |
| `Can't change auth mode` in core logs | OIDC can only be switched on while no local users besides `admin` exist: fresh database (rebuild) |
| Scan stuck `Pending` | Trivy downloads its DB from the internet on first use: `kubectl -n harbor logs sts/harbor-trivy` |
