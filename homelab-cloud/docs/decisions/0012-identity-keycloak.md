# 0012: Identity ("IAM Identity Center"): Keycloak via its operator, realm as Terraform, SSO for Argo CD

- Status: accepted
- Date: 2026-11-23

## Decision

| Piece | Choice | Why |
|---|---|---|
| Keycloak | **26.8.2** (2026-11-05), image pinned by digest | Fixes 33 CVEs, including a critical unauthenticated SAML signature bypass. Past the two-week rule. Quay re-pushes the tag for base-image fixes (four builds so far), hence the digest |
| Install | **Keycloak Operator 26.8.2**, the official manifests from `keycloak/keycloak-k8s-resources` at the release tag, by URL from a Kustomization (`k8s/platform/keycloak-operator`) | The install Keycloak's docs recommend. The Keycloak CRD is about 520 KB, over the repo's 512 KB file limit, so it isn't vendored; ServerSideApply because it's also too big for client-side apply. The operator watches its own namespace only |
| Instance | One Keycloak in namespace `keycloak`, plain HTTP inside the cluster, `https://sso.lab.macpro` through the Gateway (step-ca wildcard), `proxy.headers: xforwarded`, full-URL hostname (strict) | TLS ends at the Gateway like every other service ([ADR 0007](0007-private-pki.md)). One instance: a restart is a minute without SSO, and Argo CD's local admin stays as break-glass |
| Database | CNPG cluster **`keycloak-db`** in `databases`: 2 instances (one per worker), WAL + daily base backups to Garage under `lab/keycloak-db/` | Same shape as `pg-demo` ([ADR 0011](0011-databases-cnpg.md)): a lost worker is a failover, not an SSO outage that needs a restore |
| DB credentials | The `keycloak` role's password is a **seeded** value, not CNPG's generated app secret: OpenBao holds it at `secret/databases/keycloak-db` (CNPG creates the role with it) and `secret/keycloak/db` (Keycloak logs in with it) | Keycloak runs in another namespace than its database. Per-namespace OpenBao paths keep the "key prefix = namespace" rule ([ADR 0008](0008-secrets-openbao.md)) without copying a Secret across namespaces |
| Realm config | **Terraform**, new stack `terraform/identity`, provider `keycloak/keycloak` **5.10.0** (5.11.0 is under two weeks old), state in Garage like the other stacks, run by `make identity` (part of `make up`) | The operator's `KeycloakRealmImport` only ever *creates* a realm; changing it means delete + re-import. Terraform reconciles. It also mirrors how AWS IAM is usually managed: the platform is GitOps, the identities inside it are Terraform |
| Admin login for Terraform | The operator's **bootstrap admin** (master realm, user `admin`) from a seeded Secret, not the random one the operator would generate | Terraform has to know the password on every rebuild; it reads it from the SOPS seed (`scripts/identity.sh`, into `TF_VAR_*`, never on disk) |
| Realm `lab` | Brute-force protection (5 failures, then 1 min, doubling up to 15 min), password policy `length(12) and notUsername`, a `groups` client scope (claim `groups`, plain names) | |
| People | User **`labadmin`** (password from the seed, `make sso-password`), member of **`argocd-admins`** | One lab user for now. Real people go in as more `keycloak_user`s |
| Argo CD | OIDC straight to Keycloak (no Dex): client `argocd`, confidential, code flow only (no direct grants), secret from the seed via OpenBao `secret/argocd/oidc-keycloak`. RBAC `g, argocd-admins, role:admin`, no default role | Dex would be one more component for one client. Without a default role, a valid Keycloak login outside the group sees nothing |
| CA for the issuer | Argo CD's `oidc.config` `rootCA`, inline (the only way Argo CD takes it), kept in sync by `scripts/pki-render.py` between markers | argocd-server fetches the issuer's discovery document over HTTPS from inside the cluster |

## Secrets (all from the SOPS OpenBao seed, generated once, kept across re-runs)

| Seed key | OpenBao path(s) | Used by |
|---|---|---|
| `keycloak-db-password` | `secret/databases/keycloak-db`, `secret/keycloak/db` | CNPG `initdb`, Keycloak |
| `keycloak-admin-password` | `secret/keycloak/bootstrap-admin` | Keycloak's first start; `terraform/identity` |
| `keycloak-labadmin-password` | (none: Terraform sets it as the initial password) | `labadmin`; `make verify`'s SSO login |
| `keycloak-argocd-client-secret` | `secret/argocd/oidc-keycloak` | Argo CD; `terraform/identity` sets the same value on the client |

`keycloak` and `argocd` joined the ClusterSecretStore's namespace allow-list. Argo CD's ExternalSecret only
delivers the client secret.

## Lifecycle

Fresh on every rebuild, like the databases: `make destroy` wipes `lab/` in the backup bucket and runs
`scripts/identity.sh forget`, which drops every resource from the `identity` state (the realm is gone with the
cluster, so there is nothing to destroy). `make up` builds the cluster, waits until every Argo CD Application is
Healthy (a Lua health check makes the Keycloak CR count only once it is Ready), then `make identity` creates the
realm again.

## Tested before deploying

Against the pinned 26.8.2 image in Docker on voodoo, with the stack on local state:

- `terraform apply` created the realm, group, user, client scope + mapper, client and default scopes; a second
  plan showed no changes.
- Argo CD's side of the code flow, by hand: the login page's form (`kc-form-login`, what `scripts/sso-login-test.py`
  parses) posts back to `/auth/callback` with a code; the code exchanges with the client secret; the ID token
  has `groups: ["argocd-admins"]`. A wrong client secret (401) and the password grant (400, direct grants off)
  are rejected.
- Found on the way: Keycloak's session cookie is `Secure`, so over plain HTTP a client never sends it back
  (`cookie_not_found`). Only a test artifact here: every real hop is HTTPS.

## Found on first deploy

- The operator runs a controller per CRD, including the new `KeycloakOIDCClient` and `KeycloakSAMLClient`.
  Only two of the four CRDs were installed, so it crash-looped on `keycloaksamlclients` (404), never created the
  Keycloak pod, and `sso.lab.macpro` answered 500 (a route with no backend). Now all four, as upstream's
  `kubernetes/kustomization.yml` lists them. The Docker test ran Keycloak alone, so it couldn't catch this.
- Then Keycloak crash-looped: the operator starts it with `start --optimized`, which only works on an image
  pre-built with `kc.sh build`, and the stock image isn't ("The '--optimized' flag was used for first ever server
  start"). `spec.startOptimized: false`: Keycloak runs the build step itself at each start, about a minute
  slower. A custom pre-built image is the later optimization. (The Docker test used `start-dev`, which never
  takes that path.)
- `make verify`'s SSO check followed the redirect chain to its end, Argo CD's UI page `/applications`, which
  answers 404 to a non-browser client: a false FAIL although the login had worked (argocd-server logged "Web
  login successful"). The script now sends a browser's `Accept` header and only judges the session cookie.

Result (2026-11-23, live lab): `make identity` created 8 resources, a second plan is empty, and `make verify`
passed **52/52**, including the real SSO login (`labadmin`, group `argocd-admins`, 19 Applications visible).

## Verification

`make verify` section 10: operator rolled out, Keycloak CR Ready, `keycloak-db` healthy with 2 instances and
archiving, the realm's OIDC discovery served on `https://sso.lab.macpro` with the right issuer (TLS checked
against the lab root), and a **real SSO login**: `scripts/sso-login-test.py` signs in to Argo CD as `labadmin`
through Keycloak's login form, then checks `/api/v1/session/userinfo` (group `argocd-admins`) and that the
session can list Applications.

## Consequences

- Memory: the operator requests 450 MiB (upstream value, more than expected), Keycloak 640 MiB (limit 1 GiB),
  `keycloak-db` 2 × 256 MiB. All on the two 4 GiB workers.
- The realm is not GitOps: a change to `terraform/identity` needs `make identity` from voodoo. `make up` runs it.
- Not yet on Keycloak: the Garage UI ([ADR 0010](0010-garage-host-s3.md) said milestone 6; deferred), OpenBao's UI,
  Harbor (milestone 7), Grafana (Phase 4).
