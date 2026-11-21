#!/usr/bin/env bash
# make garage: deploy or converge Garage S3 on the Mac Pro host (ADR 0010). Idempotent: safe to re-run.
#   1. secrets   host/garage/secrets.enc.yaml (SOPS): generated once, extended when a bucket is added
#   2. TLS       s3.lab.macpro + the host IP, signed offline by the lab intermediate CA, 1 y, renewed < 30 d
#   3. deploy    compose.yaml, Caddyfile, garage.toml, tls/ -> ~/homelab-garage on the host; docker compose up
#   4. init      single-node layout, buckets, keys imported from the SOPS file (same keys after a reinstall)
#   5. creds     .cache/garage/credentials for the Terraform S3 backend (profile "tfstate")
#   6. check     TLS verifies against the lab root; the tfstate key can list its bucket
# Needs no sudo: Docker on the host runs as your user (docker group).
#   GARAGE_TARGET=local  run against this workstation's Docker instead (testing), bound to 127.0.0.1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt"
SRC="${ROOT}/host/garage"
SECRETS="${SRC}/secrets.enc.yaml"
CA="${ROOT}/.cache/ca"
CACHE="${ROOT}/.cache/garage"
S3_NAME="s3.lab.macpro"
PORT=3900
TARGET="${GARAGE_TARGET:-macpro}"
BUCKETS=(tfstate cnpg-backups)     # one key per bucket, named like the bucket, access to that bucket only
CAPACITY="${GARAGE_CAPACITY:-200G}" # layout capacity: an upper bound for placement, not a reservation

if [[ "${TARGET}" == local ]]; then
  HOST_IP=127.0.0.1
  DIR="${GARAGE_DIR:-${ROOT}/.cache/garage-local}"
  remote() { bash -c "$1"; }
else
  HOST_IP="${LAB_HOST:-192.168.8.207}"
  DIR="${GARAGE_DIR:-homelab-garage}"   # relative to the host user's home
  remote() { ssh -o BatchMode=yes "${TARGET}" "$1"; }
fi
COMPOSE="cd ${DIR} && GARAGE_BIND_IP=${HOST_IP} docker compose"
say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }

[[ -f "${SOPS_AGE_KEY_FILE}" && -f "${CA}/intermediate_ca_key" ]] || { echo "need .cache/age and .cache/ca (make pki)" >&2; exit 1; }
umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------- 1. secrets
say "secrets (${SECRETS#"${ROOT}"/})"
[[ -f "${SECRETS}" ]] && sops --decrypt "${SECRETS}" > "${TMP}/old.yaml"
python3 -I - "${TMP}/old.yaml" "${TMP}/new.yaml" "${TMP}/env" "${BUCKETS[@]}" <<'EOF'
import os, secrets, shlex, sys, yaml
old_path, new_path, env_path, *buckets = sys.argv[1:]
old = (yaml.safe_load(open(old_path)) or {}).get("stringData", {}) if os.path.exists(old_path) else {}
d = dict(old)
d.setdefault("rpc_secret", secrets.token_hex(32))
d.setdefault("admin_token", secrets.token_urlsafe(32))
d.setdefault("metrics_token", secrets.token_urlsafe(32))
for b in buckets:
    d.setdefault(f"{b}_key_id", "GK" + secrets.token_hex(12))    # Garage key id format: GK + 24 hex
    d.setdefault(f"{b}_secret_key", secrets.token_hex(32))
changed = d != old
doc = {"apiVersion": "v1", "kind": "Secret",
       "metadata": {"name": "garage", "annotations": {"homelab-cloud/note":
                    "Garage on the Mac Pro host (ADR 0010); not applied to the cluster"}},
       "stringData": d}
if changed:
    yaml.safe_dump(doc, open(new_path, "w"), sort_keys=False)
with open(env_path, "w") as f:
    for k, v in d.items():
        f.write(f"{k.replace('-', '_')}={shlex.quote(v)}\n")
print("generated/extended" if changed else "unchanged")
EOF
if [[ -f "${TMP}/new.yaml" ]]; then
  sops --encrypt --filename-override "${SECRETS}" --input-type yaml --output-type yaml "${TMP}/new.yaml" > "${SECRETS}"
  echo "  wrote ${SECRETS#"${ROOT}"/}: commit it"
fi
# shellcheck disable=SC1091
source "${TMP}/env"

# ---------------------------------------------------------------- 2. TLS
say "TLS certificate for ${S3_NAME}, ${HOST_IP}"
mkdir -p "${CACHE}/tls"
crt="${CACHE}/tls/s3.crt" key="${CACHE}/tls/s3.key"
want_sans="${S3_NAME} ${HOST_IP}"
have_sans="$( [[ -f "${crt}" ]] && step certificate inspect "${crt}" --format json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(d.get("names", [])))' || true)"
if [[ ! -f "${crt}" || "${have_sans}" != "${want_sans}" ]] || step certificate needs-renewal "${crt}" --expires-in 720h >/dev/null 2>&1; then
  step certificate create "${S3_NAME}" "${TMP}/leaf.crt" "${key}" --profile leaf \
    --ca "${CA}/intermediate_ca.crt" --ca-key "${CA}/intermediate_ca_key" --ca-password-file "${CA}/intermediate.pass" \
    --san "${S3_NAME}" --san "${HOST_IP}" --kty EC --curve P-256 --not-after 8760h \
    --no-password --insecure --force >/dev/null
  cat "${TMP}/leaf.crt" "${CA}/intermediate_ca.crt" > "${crt}"
  echo "  issued, valid until $(step certificate inspect "${crt}" --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["validity"]["end"])')"
else
  echo "  current (SANs ${have_sans})"
fi

# ---------------------------------------------------------------- 3. deploy
say "deploy to ${TARGET}:${DIR}"
mkdir -p "${TMP}/stage/tls"
cp "${SRC}/compose.yaml" "${SRC}/Caddyfile" "${TMP}/stage/"
cp "${crt}" "${key}" "${TMP}/stage/tls/"
env rpc_secret="${rpc_secret}" admin_token="${admin_token}" metrics_token="${metrics_token}" \
  python3 -I -c 'import os,string,sys; print(string.Template(open(sys.argv[1]).read()).substitute(os.environ), end="")' \
  "${SRC}/garage.toml.tmpl" > "${TMP}/stage/garage.toml"
hash="$(cd "${TMP}/stage" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
old_hash="$(remote "cat ${DIR}/.deployed 2>/dev/null || true")"
tar -C "${TMP}/stage" -cf - . | remote "mkdir -p -m 700 ${DIR} && tar -xf - -C ${DIR} && chmod 600 ${DIR}/garage.toml ${DIR}/tls/s3.key"
remote "${COMPOSE} up -d --remove-orphans --quiet-pull" 2>&1 | grep -vE '^\s*$' | sed 's/^/  /'
if [[ -n "${old_hash}" && "${old_hash}" != "${hash}" ]]; then
  echo "  config changed: restarting"
  remote "${COMPOSE} restart" 2>&1 | sed 's/^/  /'
fi
remote "echo ${hash} > ${DIR}/.deployed"

# ---------------------------------------------------------------- 4. init
say "layout, buckets, keys"
g() { remote "${COMPOSE} exec -T garage /garage $* 2>&1" | grep -v 'garage_net::'; }
for _ in $(seq 1 30); do g status >/dev/null 2>&1 && break; sleep 2; done
node="$(g node id -q | head -1 | cut -d@ -f1)"
[[ "${node}" =~ ^[0-9a-f]{64}$ ]] || { echo "Garage didn't start: ${node}" >&2; remote "${COMPOSE} logs --tail 30 garage" >&2; exit 1; }
if g layout show | grep -q "^${node:0:16} "; then
  echo "  layout: node ${node:0:16} already has a role"
else
  ver="$(g layout show | sed -n 's/.*Current cluster layout version: \([0-9]*\).*/\1/p' | head -1)"
  g layout assign -z mac-pro -c "${CAPACITY}" "${node}" >/dev/null
  g layout apply --version "$(( ${ver:-0} + 1 ))" | tail -1 | sed 's/^/  /'
fi
for b in "${BUCKETS[@]}"; do
  v="${b//-/_}"; kid_var="${v}_key_id"; sec_var="${v}_secret_key"
  g bucket info "${b}" >/dev/null 2>&1 || { g bucket create "${b}" >/dev/null; echo "  bucket ${b}: created"; }
  g key info "${!kid_var}" >/dev/null 2>&1 \
    || { g key import --yes -n "${b}" "${!kid_var}" "${!sec_var}" >/dev/null; echo "  key ${b}: imported"; }
  g bucket allow --read --write "${b}" --key "${!kid_var}" >/dev/null
  echo "  ${b}: key ${!kid_var} read+write"
done

# ---------------------------------------------------------------- 5. credentials for Terraform
cat > "${CACHE}/credentials" <<CREDS
# written by scripts/garage-deploy.sh from host/garage/secrets.enc.yaml; git-ignored
[tfstate]
aws_access_key_id = ${tfstate_key_id}
aws_secret_access_key = ${tfstate_secret_key}
CREDS
chmod 600 "${CACHE}/credentials"

# ---------------------------------------------------------------- 6. check
say "check"
url="https://${S3_NAME}:${PORT}"
code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "${S3_NAME}:${PORT}:${HOST_IP}" \
  --cacert "${ROOT}/k8s/platform/step-ca/config/root_ca.crt" \
  --aws-sigv4 "aws:amz:garage:s3" --user "${tfstate_key_id}:${tfstate_secret_key}" \
  -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "${url}/tfstate?list-type=2")"
[[ "${code}" == 200 ]] && echo "  ${url}: TLS verifies against the lab root, tfstate key lists its bucket" \
  || { echo "  ${url}: HTTP ${code} (expected 200)" >&2; exit 1; }
other="$(curl -s -o /dev/null -w '%{http_code}' --resolve "${S3_NAME}:${PORT}:${HOST_IP}" \
  --cacert "${ROOT}/k8s/platform/step-ca/config/root_ca.crt" \
  --aws-sigv4 "aws:amz:garage:s3" --user "${tfstate_key_id}:${tfstate_secret_key}" \
  -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "${url}/cnpg-backups?list-type=2")"
[[ "${other}" == 403 ]] && echo "  isolation: the tfstate key is refused on cnpg-backups (403)" \
  || { echo "  isolation: tfstate key got HTTP ${other} on cnpg-backups (expected 403)" >&2; exit 1; }

if [[ "${TARGET}" != local ]]; then
  resolved="$(getent ahostsv4 "${S3_NAME}" | awk 'NR==1{print $1}')"
  if [[ "${resolved}" != "${HOST_IP}" ]]; then
    printf '\n\033[33m!! %s resolves to "%s", not %s.\033[0m Add an AdGuard rewrite (exact names win over *.lab.macpro):\n' \
      "${S3_NAME}" "${resolved:-nothing}" "${HOST_IP}"
    printf '   AdGuard Home -> Filters -> DNS rewrites -> Add: domain %s, answer %s\n' "${S3_NAME}" "${HOST_IP}"
  else
    echo "  DNS: ${S3_NAME} -> ${HOST_IP}"
  fi
fi
