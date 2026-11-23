# Runbook: identity (Keycloak, SSO)

Design: [ADR 0012](../decisions/0012-identity-keycloak.md). Keycloak itself is GitOps (`k8s/platform/keycloak`,
operator in `k8s/platform/keycloak-operator`); the realm `lab` and everything in it is Terraform
(`terraform/identity`, `make identity`).

## Access

| | |
|---|---|
| Lab user | `labadmin` (group `argocd-admins`), password `make sso-password` |
| Argo CD | https://argocd.lab.macpro → **LOG IN VIA KEYCLOAK** |
| Account page | https://sso.lab.macpro/realms/lab/account |
| Admin console | https://sso.lab.macpro/admin (realm **master**, user `admin`, password: `SOPS_AGE_KEY_FILE=.cache/age/key.txt .tools/bin/sops -d --extract '["data"]["keycloak-admin-password"]' k8s/platform/openbao/seed.enc.yaml \| base64 -d`) |
| Issuer | `https://sso.lab.macpro/realms/lab` |

Changes made in the admin console to anything Terraform manages are reverted by the next `make identity`.

## Check

```sh
make verify                                            # section 10, includes a real Argo CD SSO login
kubectl -n keycloak get keycloak keycloak              # READY True
kubectl -n keycloak get pods                           # keycloak-0 + keycloak-operator
kubectl -n databases get cluster keycloak-db           # Cluster in healthy state, 2 instances
make identity                                          # plan shows no changes when nothing drifted
```

## Common jobs

| Job | How |
|---|---|
| Add a person | A `keycloak_user` (+ `keycloak_user_groups`) in `terraform/identity/main.tf`, then `make identity`. Give them a temporary password (`initial_password { temporary = true }`) |
| Give a group Argo CD rights | `policy.csv` in `k8s/bootstrap/argocd/values.yaml`, e.g. `g, <group>, role:readonly`, commit + push |
| Add an OIDC client (Harbor, Grafana…) | A `keycloak_openid_client` in `terraform/identity`, its secret as a new seed value (`scripts/openbao-seed.sh`), an OpenBao path in the consumer's namespace, then an ExternalSecret there |
| Rotate the Argo CD client secret | Delete `keycloak-argocd-client-secret` from the seed (`make openbao-seed` regenerates missing values), write the new value to OpenBao `secret/argocd/oidc-keycloak`, `make identity`, then `kubectl -n argocd delete secret argocd-oidc-keycloak` (ESO recreates it) |
| Keycloak down, need Argo CD | Local `admin`: [cluster-access.md](cluster-access.md) |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Argo CD login button missing | `kubectl -n argocd get cm argocd-cm -o yaml \| grep -A3 oidc.config`; argocd-server logs `oidc` errors at start |
| `failed to query provider` / x509 errors in argocd-server | Its `rootCA` doesn't match the lab root: re-run `python3 scripts/pki-render.py`, commit, push |
| `invalid_client` after login | Client secret differs between Keycloak and Argo CD: compare OpenBao `secret/argocd/oidc-keycloak` with the seed, then `make identity` |
| Logged in, but Argo CD shows nothing | The user isn't in a group that `policy.csv` maps: `GET /api/v1/session/userinfo` lists the groups Argo CD saw |
| `make identity` waits for Keycloak | `kubectl -n keycloak get keycloak keycloak -o yaml` (status conditions); the operator logs; is `keycloak-db` healthy? |
| `make identity` fails with 401 | Keycloak was started before the bootstrap-admin Secret existed and created no admin (or a different one). On a fresh database: delete `keycloak-0` once the Secret exists |
| Account locked | Brute-force protection: 5 failures lock it for 1 min, doubling up to 15. Admin console → Users → the user → unlock, or wait |
