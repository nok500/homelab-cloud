#!/usr/bin/env bash
# make state-migrate: move the local Terraform state of terraform/host and terraform/talos into Garage (ADR 0010).
# One-time. Safe to re-run: a stack already in Garage is skipped. Per stack, host first (talos reads host's outputs):
#   1. preconditions: Garage reachable over TLS at s3.lab.macpro, no state for the stack in the bucket yet
#   2. an age-encrypted copy of the local state in .cache/state-history/<stack>/ (…-pre-garage)
#   3. terraform init -migrate-state, then the same resource count and serial must be in Garage
#   4. only then the plaintext local terraform.tfstate(.backup) files are removed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
TF="${ROOT}/scripts/tf.sh"
S3="s3.lab.macpro"
HOST_IP="${LAB_HOST:-192.168.8.207}"
say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }

say "preconditions"
[[ -f "${ROOT}/.cache/garage/credentials" ]] || { echo "run make garage first" >&2; exit 1; }
resolved="$(getent ahostsv4 "${S3}" | awk 'NR==1{print $1}')"
[[ "${resolved}" == "${HOST_IP}" ]] || {
  echo "${S3} resolves to '${resolved:-nothing}', not ${HOST_IP}: add the AdGuard rewrite first (docs/runbooks/terraform-state.md)" >&2
  exit 1; }
curl -sf -o /dev/null "https://${S3}:3900/" -w '' 2>/dev/null || code=$?
# an anonymous request is refused (403), which curl -f reports as 22; anything else is a TLS or network problem
[[ "${code:-0}" == 22 ]] || { echo "https://${S3}:3900 not reachable or TLS doesn't verify (curl exit ${code:-0})" >&2; exit 1; }
echo "  ${S3} -> ${HOST_IP}, TLS verifies against the system trust store"

count() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("resources",[])), d.get("serial",0))' "$1"; }

for stack in host talos; do
  dir="${ROOT}/terraform/${stack}"
  local_state="${dir}/terraform.tfstate"
  say "${stack}"
  if [[ ! -s "${local_state}" ]]; then
    if "${TF}" "${stack}" init -input=false >/dev/null 2>&1 && [[ -n "$("${TF}" "${stack}" state list 2>/dev/null)" ]]; then
      echo "  already in Garage ($("${TF}" "${stack}" state list | wc -l) resources): skipped"
      # leftovers of an earlier migration: Terraform's empty local file and its plaintext .backup
      [[ -e "${local_state}" || -e "${local_state}.backup" ]] && rm -f "${local_state}" "${local_state}.backup" \
        && echo "  removed leftover local state files"
    else
      echo "  no local state and nothing in Garage: nothing to migrate"
    fi
    continue
  fi
  read -r want_n want_serial < <(count "${local_state}")
  echo "  local: ${want_n} resources, serial ${want_serial}"

  mkdir -p "${ROOT}/.cache/state-history/${stack}"
  backup="${ROOT}/.cache/state-history/${stack}/$(date +%Y%m%d-%H%M%S)-pre-garage.tfstate.age"
  age -r "$(age-keygen -y "${ROOT}/.cache/age/key.txt")" -o "${backup}" "${local_state}"
  echo "  encrypted copy: ${backup#"${ROOT}"/}"
  before="$(mktemp)"; after="$(mktemp)"; cp "${local_state}" "${before}"   # Terraform truncates the local file

  # -force-copy answers "copy existing state to the new backend?" with yes. Terraform refuses on its own if the
  # new backend already holds a different state for this key.
  "${TF}" "${stack}" init -input=false -migrate-state -force-copy -no-color | grep -E 'Successfully|Error|copied' | sed 's/^/  /'

  # Terraform writes the copy with a new lineage and serial 1, so compare the content: resources and outputs
  "${TF}" "${stack}" state pull > "${after}"
  if ! python3 - "${before}" "${after}" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:])
same = lambda k: json.dumps(a.get(k), sort_keys=True) == json.dumps(b.get(k), sort_keys=True)
print(f"  Garage: {len(b.get('resources', []))} resources, serial {b.get('serial')}; resources identical: {same('resources')}, outputs identical: {same('outputs')}")
sys.exit(0 if same("resources") and same("outputs") else 1)
PY
  then
    shred -u "${before}" "${after}"
    echo "  MISMATCH: local files left in place (and ${backup#"${ROOT}"/}). Investigate before running Terraform again." >&2
    exit 1
  fi
  shred -u "${before}" "${after}"
  rm -f "${local_state}" "${local_state}.backup"
  echo "  removed the plaintext local state files"
done

say "plan (expect no changes)"
planlog="$(mktemp)"; trap 'rm -f "${planlog}"' EXIT
for stack in host talos; do
  set +e; "${TF}" "${stack}" plan -input=false -detailed-exitcode -no-color >"${planlog}" 2>&1; rc=$?; set -e
  case "${rc}" in
    0) echo "  ${stack}: no changes" ;;
    2) echo "  ${stack}: CHANGES planned (state migrated fine, but review: scripts/tf.sh ${stack} plan)"; grep -E '^\s+[#~+-]|Plan:' "${planlog}" | head -15 ;;
    *) echo "  ${stack}: plan failed"; tail -15 "${planlog}" ;;
  esac
done
