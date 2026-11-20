#!/usr/bin/env bash
# (Re)build k8s/platform/openbao/seed.enc.yaml: the ONE bootstrap secret OpenBao needs (ADR 0008).
#   unseal.key       32 random bytes, static auto-unseal key   (generated once, kept across re-runs)
#   admin-password   OpenBao `admin` userpass login             (generated once, kept across re-runs)
#   step-ca-*        seed values copied in by self-initialization (from .cache/ca)
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

python3 -I - "${TMP}/old.yaml" "${CA}" > "${TMP}/seed.yaml" <<'EOF'
import base64, os, secrets, sys, yaml
old_path, ca = sys.argv[1:]
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
}
print("---")
print(yaml.dump({"apiVersion": "v1", "kind": "Secret",
                 "metadata": {"name": "openbao-seed", "namespace": "openbao"},
                 "type": "Opaque", "data": data}, sort_keys=False), end="")
EOF

(cd "${ROOT}" && sops --encrypt --filename-override "${OUT}" "${TMP}/seed.yaml" > "${OUT}.tmp")
mv "${OUT}.tmp" "${OUT}"; chmod 0644 "${OUT}"
echo "wrote ${OUT#"${ROOT}/"} (keys: $(sops --decrypt "${OUT}" | python3 -c 'import sys,yaml; print(" ".join(yaml.safe_load(sys.stdin)["data"]))'))"
