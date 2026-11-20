#!/usr/bin/env bash
# ONE-TIME: the lab's private PKI (ACM equivalent, ADR 0007) and the age key for SOPS.
#
#   root CA (10 y, name-constrained to lab.macpro + cluster.local)  -> key stays OFFLINE in .cache/ca
#   intermediate CA (5 y)                                           -> key + password SOPS-encrypted in Git
#   JWK provisioner "step-issuer" (cert-manager's way in)           -> password SOPS-encrypted in Git
#
# Survives `make destroy && make up`, so the root is trusted once per machine. Refuses to run twice:
# a new root means re-trusting it everywhere. BACK UP .cache/ca and .cache/age (password manager / offline).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
CA="${ROOT}/.cache/ca"
AGE_KEY="${ROOT}/.cache/age/key.txt"
OUT="${ROOT}/k8s/platform/step-ca"
NS="step-ca"
SVC="step-ca.${NS}.svc.cluster.local"

[[ -e "${CA}/root_ca.crt" ]] && { echo "PKI already exists in ${CA}; refusing to overwrite it" >&2; exit 1; }
for t in step sops age-keygen; do command -v "$t" >/dev/null || { echo "missing $t: run make tools" >&2; exit 1; }; done

umask 077
mkdir -p "${CA}" "$(dirname "${AGE_KEY}")" "${OUT}"

echo ">> age key (SOPS recipient)"
[[ -f "${AGE_KEY}" ]] || age-keygen -o "${AGE_KEY}" 2>/dev/null
AGE_PUB="$(age-keygen -y "${AGE_KEY}")"
umask 022
cat > "${ROOT}/.sops.yaml" <<EOF
---
# SOPS: *.enc.yaml files are encrypted to the lab's age key (.cache/age/key.txt, never committed).
# Only Secret payloads are encrypted, so diffs still show which secret changed.
creation_rules:
  - path_regex: \.enc\.yaml\$
    encrypted_regex: ^(data|stringData)\$
    age: ${AGE_PUB}
EOF
umask 077

pw() { python3 -c 'import secrets; print(secrets.token_urlsafe(32))'; }
pw > "${CA}/root.pass"; pw > "${CA}/intermediate.pass"; pw > "${CA}/provisioner.pass"

echo ">> root CA (offline key, name-constrained)"
cat > "${CA}/root.tpl" <<'EOF'
{
  "subject": {{ toJson .Subject }},
  "issuer": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "basicConstraints": {"isCA": true, "maxPathLen": 1},
  "nameConstraints": {"critical": true, "permittedDNSDomains": ["lab.macpro", "cluster.local"]}
}
EOF
step certificate create "homelab-cloud Root CA" "${CA}/root_ca.crt" "${CA}/root_ca_key" \
  --template "${CA}/root.tpl" --kty EC --curve P-256 --not-after 87600h \
  --password-file "${CA}/root.pass"

echo ">> intermediate CA"
step certificate create "homelab-cloud Intermediate CA" "${CA}/intermediate_ca.crt" "${CA}/intermediate_ca_key" \
  --profile intermediate-ca --ca "${CA}/root_ca.crt" --ca-key "${CA}/root_ca_key" \
  --ca-password-file "${CA}/root.pass" --password-file "${CA}/intermediate.pass" \
  --kty EC --curve P-256 --not-after 43800h

echo ">> JWK provisioner for step-issuer"
step crypto jwk create "${CA}/provisioner.pub.json" "${CA}/provisioner.key.json" \
  --kty EC --curve P-256 --use sig --password-file "${CA}/provisioner.pass"
step crypto jose format < "${CA}/provisioner.key.json" > "${CA}/provisioner.encrypted"

umask 022
echo ">> public material -> Git"
python3 -I "${ROOT}/scripts/pki-render.py"

echo ">> secrets -> SOPS"
umask 077
python3 -I - "${CA}" "${NS}" > "${CA}/secrets.yaml" <<'EOF'
import sys, yaml
ca, ns = sys.argv[1:]
rd = lambda f: open(f"{ca}/{f}").read()
class Lit(str): pass
yaml.add_representer(Lit, lambda d, s: d.represent_scalar("tag:yaml.org,2002:str", s, style="|"))
docs = [
    {"apiVersion": "v1", "kind": "Secret", "type": "smallstep.com/private-keys",
     "metadata": {"name": "step-ca-secrets", "namespace": ns},
     "stringData": {"intermediate_ca_key": Lit(rd("intermediate_ca_key"))}},
    {"apiVersion": "v1", "kind": "Secret", "type": "smallstep.com/ca-password",
     "metadata": {"name": "step-ca-ca-password", "namespace": ns},
     "stringData": {"password": rd("intermediate.pass").strip()}},
    {"apiVersion": "v1", "kind": "Secret",
     "metadata": {"name": "step-issuer-provisioner-password", "namespace": ns},
     "stringData": {"password": rd("provisioner.pass").strip()}},
]
print("---\n" + "---\n".join(yaml.dump(d, sort_keys=False) for d in docs), end="")
EOF
(cd "${ROOT}" && sops --encrypt --filename-override "${OUT}/secrets.enc.yaml" "${CA}/secrets.yaml" > "${OUT}/secrets.enc.yaml")
rm -f "${CA}/secrets.yaml"
chmod 0644 "${OUT}/secrets.enc.yaml"

echo
step certificate inspect "${CA}/root_ca.crt" --short
echo "root fingerprint (SHA-256): $(step certificate fingerprint "${CA}/root_ca.crt")"
echo
echo "Done. BACK UP ${CA} and ${AGE_KEY}: losing the age key means re-running this (and re-trusting a new root)."
echo "Trust the root on this machine: see docs/runbooks/pki.md"
