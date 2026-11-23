#!/usr/bin/env bash
# (Re)build k8s/platform/openbao/seed.enc.yaml: the ONE bootstrap secret OpenBao needs (ADR 0008).
#   unseal.key       32 random bytes, static auto-unseal key   (generated once, kept across re-runs)
#   admin-password   OpenBao `admin` userpass login             (generated once, kept across re-runs)
#   step-ca-*        seed values copied in by self-initialization (from .cache/ca)
#   databases-s3-*   Garage key for CNPG backups (from host/garage/secrets.enc.yaml)
#   keycloak-*       Keycloak DB password, bootstrap admin, the lab user's password, the Argo CD OIDC client
#                    secret (generated once, kept across re-runs; ADR 0012)
#   harbor-*         Harbor (ADR 0013): admin + DB passwords, its fixed internal keys (the chart would otherwise
#                    regenerate them on every Argo CD render), token-signing key pair, registry htpasswd, and
#                    the Garage key for bucket harbor; keycloak-harbor-client-secret for its OIDC client
# OpenBao reads these files only on first start (self-init), then everything comes from OpenBao via
# External Secrets. Re-run after adding a seed value, then commit + push.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt"
CA="${ROOT}/.cache/ca"
OUT="${ROOT}/k8s/platform/openbao/seed.enc.yaml"

[[ -f "${SOPS_AGE_KEY_FILE}" && -f "${CA}/intermediate_ca_key" ]] || { echo "need .cache/age and .cache/ca (make pki)" >&2; exit 1; }

umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# keep the unseal key + admin password stable across re-runs (a new unseal key can't open existing storage)
if [[ -f "${OUT}" ]]; then
  sops --decrypt "${OUT}" > "${TMP}/old.yaml"
fi

# the CNPG backup key for Garage (host/garage/secrets.enc.yaml, written by make garage; ADR 0010)
GARAGE_SECRETS="${ROOT}/host/garage/secrets.enc.yaml"
[[ -f "${GARAGE_SECRETS}" ]] || { echo "missing ${GARAGE_SECRETS#"${ROOT}"/}: run make garage first" >&2; exit 1; }
sops --decrypt "${GARAGE_SECRETS}" > "${TMP}/garage.yaml"

# htpasswd for the registry's bcrypt line (only run when that line is first generated)
export HTTPD_IMAGE="docker.io/library/httpd:2.4.71-alpine@sha256:5ddc13143f251758eb7277bdb5ec5afee3a67c5a226861ec4f12b6bcf5e62b8f"
python3 -I - "${TMP}/old.yaml" "${CA}" "${TMP}/garage.yaml" > "${TMP}/seed.yaml" <<'EOF'
import base64, os, secrets, sys, yaml
HTTPD_IMAGE = os.environ["HTTPD_IMAGE"]
old_path, ca, garage_path = sys.argv[1:]
garage = yaml.safe_load(open(garage_path))["stringData"]
old = {}
if os.path.exists(old_path):
    old = (yaml.safe_load(open(old_path)) or {}).get("data", {})
rd = lambda f: open(f"{ca}/{f}", "rb").read()
b64 = lambda b: base64.b64encode(b).decode()
data = {
    "unseal.key": old.get("unseal.key") or b64(secrets.token_bytes(32)),
    "admin-password": old.get("admin-password") or b64(secrets.token_urlsafe(32).encode()),
    "step-ca-intermediate-key": b64(rd("intermediate_ca_key")),
    "step-ca-ca-password": b64(rd("intermediate.pass").strip()),
    "step-ca-provisioner-password": b64(rd("provisioner.pass").strip()),
    "databases-s3-access-key-id": b64(garage["cnpg-backups_key_id"].encode()),
    "databases-s3-secret-access-key": b64(garage["cnpg-backups_secret_key"].encode()),
}
# Keycloak (ADR 0012): generated once, then stable. terraform/identity reads them too (make identity).
for key in ("keycloak-db-password", "keycloak-admin-password", "keycloak-labadmin-password",
            "keycloak-argocd-client-secret"):
    data[key] = old.get(key) or b64(secrets.token_urlsafe(32).encode())

# Harbor (ADR 0013). Lengths are Harbor's: secretKey/core/jobservice/registry secrets exactly 16 chars, the
# CSRF key exactly 32. Generated once, then stable.
fixed = {"harbor-admin-password": lambda: secrets.token_urlsafe(32),
         "harbor-db-password": lambda: secrets.token_urlsafe(32),
         "harbor-secret-key": lambda: secrets.token_hex(8),
         "harbor-core-secret": lambda: secrets.token_hex(8),
         "harbor-jobservice-secret": lambda: secrets.token_hex(8),
         "harbor-registry-http-secret": lambda: secrets.token_hex(8),
         "harbor-csrf-key": lambda: secrets.token_hex(16),
         "keycloak-harbor-client-secret": lambda: secrets.token_urlsafe(32)}
for key, gen in fixed.items():
    data[key] = old.get(key) or b64(gen().encode())
data["harbor-s3-access-key-id"] = b64(garage["harbor_key_id"].encode())
data["harbor-s3-secret-access-key"] = b64(garage["harbor_secret_key"].encode())

# Token-signing key pair (core signs registry tokens with it): RSA 4096, self-signed, 10 years.
if "harbor-token-key" in old and "harbor-token-cert" in old:
    data["harbor-token-key"], data["harbor-token-cert"] = old["harbor-token-key"], old["harbor-token-cert"]
else:
    import datetime
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    k = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "harbor-token-ca")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(k.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now)
            .not_valid_after(now + datetime.timedelta(days=3650)).sign(k, hashes.SHA256()))
    data["harbor-token-key"] = b64(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                   serialization.NoEncryption()))
    data["harbor-token-cert"] = b64(cert.public_bytes(serialization.Encoding.PEM))

# Registry basic-auth user (core -> registry): password + its bcrypt htpasswd line, regenerated together.
# bcrypt isn't in Python's stdlib; htpasswd from a pinned httpd image makes the line once.
if "harbor-registry-password" in old and "harbor-registry-htpasswd" in old:
    data["harbor-registry-password"] = old["harbor-registry-password"]
    data["harbor-registry-htpasswd"] = old["harbor-registry-htpasswd"]
else:
    import subprocess
    pw = secrets.token_urlsafe(24)
    line = subprocess.run(
        ["docker", "run", "--rm", "-i", HTTPD_IMAGE, "htpasswd", "-niB", "harbor_registry_user"],
        input=pw + "\n", capture_output=True, text=True, check=True).stdout.strip()
    data["harbor-registry-password"] = b64(pw.encode())
    data["harbor-registry-htpasswd"] = b64(line.encode())
print("---")
print(yaml.dump({"apiVersion": "v1", "kind": "Secret",
                 "metadata": {"name": "openbao-seed", "namespace": "openbao"},
                 "type": "Opaque", "data": data}, sort_keys=False), end="")
EOF

(cd "${ROOT}" && sops --encrypt --filename-override "${OUT}" "${TMP}/seed.yaml" > "${OUT}.tmp")
mv "${OUT}.tmp" "${OUT}"; chmod 0644 "${OUT}"
echo "wrote ${OUT#"${ROOT}/"} (keys: $(sops --decrypt "${OUT}" | python3 -c 'import sys,yaml; print(" ".join(yaml.safe_load(sys.stdin)["data"]))'))"
