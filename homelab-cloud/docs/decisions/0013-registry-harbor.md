# 0013: Container registry ("ECR"): Harbor on Garage S3 and CNPG, Keycloak SSO, Trivy, nodes pull from it

- Status: accepted
- Date: 2026-11-23

## Decision

| Piece | Choice | Why |
|---|---|---|
| Harbor | **2.15.4** via chart **1.19.4** (helm.goharbor.io) | 2.15.5 (2026-11-12) and 2.16.0 (2026-11-10) are under two weeks old and list no security fixes; 2.15.3 had six advisories, all fixed in 2.15.4 |
| Hostname | **https://registry.lab.macpro**, the chart's own Gateway API `HTTPRoute` (`expose.type: route`) on the lab Gateway; TLS ends there, no chart certificates, no nginx | A role name like `sso.lab.macpro`; image refs read `registry.lab.macpro/<project>/<image>` |
| Layers | **Garage S3**, bucket `harbor` (its own key), prefix `/lab`; `disableredirect: true` | Durable and outside the cluster like the other S3 uses. Without the redirect flag the registry sends clients to pre-signed Garage URLs: nodes would also have to trust the lab CA for `s3.lab.macpro`, and pulls would leave the VPC |
| Database | CNPG **`harbor-db`** in `databases` (2 instances, backups to Garage `lab/harbor-db/`), owner password seeded (`secret/databases/harbor-db` = `secret/harbor/db`) | Same shape as `keycloak-db` ([ADR 0012](0012-identity-keycloak.md)) |
| Redis | The chart's internal `redis-photon` | Harbor's own image (no Bitnami); job queue + cache only |
| Scanning | **Trivy** on (the chart's adapter) | The brief's "ECR with Trivy scanning"; Trivy Operator in Phase 5 covers the cluster side |
| Login | **OIDC via Keycloak**: client `harbor` (terraform/identity), group **`harbor-admins`** = Harbor system admins, auto-onboarding, `preferred_username` as the user name. Set through `CONFIG_OVERWRITE_JSON` from an ExternalSecret (it carries the client secret), not the chart's `configureUserSettings` | Same IdP as Argo CD. The local `admin` stays for the CLI and break-glass |
| Secrets | **Every** secret the chart would generate comes from OpenBao (`secret/harbor/*`): core secret, CSRF key, encryption key, admin password, token-signing key pair, jobservice + registry secrets, the registry's basic-auth password **and its bcrypt htpasswd line**, the Garage key, the DB password | The chart's defaults are random and fall back to Helm `lookup`, which Argo CD doesn't run: each sync would mint new keys (broken sessions, a new token CA, a new registry password that no longer matches). Checked: two renders of the chart with these values are identical |
| Trust | `caBundleSecretName: harbor-ca` (the lab root, a copy kept by `scripts/pki-render.py`): registry → Garage, core → Keycloak, Trivy | All three call `*.lab.macpro` over HTTPS |
| Node pulls | A Talos **`RegistryTLSConfig`** for `registry.lab.macpro` with the lab root CA (terraform/talos), applied without a reboot (dry-run: "Applied configuration without a reboot") | containerd on every node trusts the lab CA for the registry only, not system-wide (a `TrustedRootsConfig` would) |

## Lifecycle

Fresh per rebuild, like the databases ([ADR 0011](0011-databases-cnpg.md)): `make destroy` wipes `s3://harbor/lab/`
as well as the WAL archive. Harbor's database knows what's in the bucket, so keeping layers without it would
only leave orphans. Phase 4 CI pushes images again.

## Seed values (generated once, kept across re-runs)

`harbor-admin-password`, `harbor-db-password`, `harbor-secret-key`, `harbor-core-secret`, `harbor-jobservice-secret`,
`harbor-registry-http-secret` (16 characters each, Harbor's required length), `harbor-csrf-key` (32),
`harbor-registry-password` + `harbor-registry-htpasswd` (bcrypt; Python has no bcrypt in its standard library, so
`htpasswd` runs once from a pinned `httpd:2.4.71-alpine` image), `harbor-token-key` + `harbor-token-cert` (RSA 4096,
self-signed, 10 years), `harbor-s3-*` (from `host/garage/secrets.enc.yaml`), `keycloak-harbor-client-secret`.

## Tested before deploying

- Harbor's own registry image (`registry-photon:v2.15.4`, distribution v2.8.3) in Docker on voodoo against the
  real Garage bucket, the lab CA in `/harbor_cust_cert` (what the chart mounts): `crane copy` of busybox and the
  digest read back both matched upstream. With a `regionendpoint` this driver uses path-style URLs, which Garage
  needs. The test prefix was wiped afterwards.
- The seeded htpasswd line verified against its password (`htpasswd -v`).
- `helm template` twice with the lab values: identical output.
- The Talos document: `talosctl patch --dry-run` accepted it, no reboot.

## Found on first deploy

- Pushes failed: `/service/token` answered 500, `unable to get PrivateKey from PEM type: PRIVATE KEY`. Harbor's
  token service only reads a PKCS#1 key (PEM type `RSA PRIVATE KEY`); the seed had made PKCS#8. `openbao-seed.sh`
  now writes PKCS#1 and re-encodes an existing PKCS#8 value (same key and certificate). The local tests never
  touched the token key: the registry test runs without core, and a chart render can't judge its content.
- Two `make verify` checks were wrong, not Harbor: the pod-pull check used `kubectl run -i`, whose attach comes
  after `echo` has already exited (output lost, pod left behind), and the scan check re-queued a scan on every
  try, resetting the status to `Running` each time. Now: run, wait for `Succeeded`, read the log; and queue a
  scan only when there is none. Trivy's first scan waits for its vulnerability DB download (more than 5 min).

## Verification

`make verify` section 11: every Harbor component Ready; `harbor-db` healthy, 2 instances, archiving; the health
API all green over the lab CA; auth mode `oidc_auth` and `/c/oidc/login` redirecting to the lab realm; a push of
busybox to `library/verify-busybox` with `crane`; a Trivy scan reaching `Success`; and a pod pulling that image
from `registry.lab.macpro`.

## Consequences

- Memory: requests about 1.2 GiB across core, jobservice, registry, portal, Trivy and Redis, plus `harbor-db`
  2 × 256 MiB, on the 10 GiB workers ([ADR 0002](0002-vm-sizing.md) log, 2026-11-23).
- Large pushes go through Cilium's Envoy on the Gateway; its default timeouts are untested beyond small images
  (revisit with Phase 4 CI).
- Robot accounts and projects for CI are Phase 4 (likely Terraform, like the realm).
