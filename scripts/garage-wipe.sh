#!/usr/bin/env bash
# Delete every object under a prefix in a Garage bucket (ADR 0011: make destroy empties s3://cnpg-backups/lab/,
# so each rebuild's databases start with an empty WAL archive; CNPG refuses to archive into a used one).
#   usage: scripts/garage-wipe.sh <bucket> <prefix>      e.g. cnpg-backups lab/
# Uses that bucket's own key from host/garage/secrets.enc.yaml; S3 requests are signed by curl (SigV4).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt"
bucket="${1:?usage: garage-wipe.sh <bucket> <prefix>}"
prefix="${2:?usage: garage-wipe.sh <bucket> <prefix>}"
[[ -n "${prefix//\//}" ]] || { echo "refusing to wipe a whole bucket: give a non-empty prefix" >&2; exit 1; }
ENDPOINT="https://s3.lab.macpro:3900"
CA="${ROOT}/k8s/platform/step-ca/config/root_ca.crt"

read -r key_id secret < <(sops --decrypt "${ROOT}/host/garage/secrets.enc.yaml" | python3 -c '
import sys, yaml; d = yaml.safe_load(sys.stdin)["stringData"]; b = sys.argv[1]
print(d[f"{b}_key_id"], d[f"{b}_secret_key"])' "${bucket}")
s3() { curl -fsS --cacert "${CA}" --aws-sigv4 "aws:amz:garage:s3" --user "${key_id}:${secret}" \
  -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "$@"; }

deleted=0 token=""
while :; do
  q="list-type=2&prefix=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${prefix}")"
  [[ -n "${token}" ]] && q+="&continuation-token=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "${token}")"
  page="$(s3 "${ENDPOINT}/${bucket}?${q}")"
  mapfile -t keys < <(python3 -c '
import sys, xml.etree.ElementTree as ET
r = ET.fromstring(sys.stdin.read()); ns = {"s": r.tag.split("}")[0].strip("{")}
for k in r.findall("s:Contents/s:Key", ns): print(k.text)' <<<"${page}")
  for k in "${keys[@]}"; do
    s3 -X DELETE "${ENDPOINT}/${bucket}/$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${k}")" -o /dev/null
    deleted=$((deleted + 1))
  done
  token="$(python3 -c '
import sys, xml.etree.ElementTree as ET
r = ET.fromstring(sys.stdin.read()); ns = {"s": r.tag.split("}")[0].strip("{")}
t = r.find("s:NextContinuationToken", ns); print(t.text if t is not None else "")' <<<"${page}")"
  [[ -n "${token}" ]] || break
done
echo "s3://${bucket}/${prefix}: ${deleted} objects deleted"
