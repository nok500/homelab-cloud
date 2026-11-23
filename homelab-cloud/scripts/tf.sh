#!/usr/bin/env bash
# Terraform for one stack, adding the two things Garage can't do for the S3 backend (ADR 0010):
#   lock     an flock on this workstation (.cache/terraform.lock) around every command that can touch state.
#            Garage ignores If-None-Match, so Terraform's own S3 lockfile doesn't actually lock.
#   history  after a successful command that can change state, an age-encrypted copy of the state goes to
#            .cache/state-history/<stack>/ (the last 20, only when it changed). Garage has no object versioning.
# Read-only commands (output, show, validate, fmt, version, providers, graph) skip both.
#   usage: scripts/tf.sh <host|talos|identity> <terraform args...>
#   restore: docs/runbooks/terraform-state.md
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
stack="${1:?usage: tf.sh <host|talos|identity> <terraform args...>}"; shift
dir="${TF_STACK_DIR:-${ROOT}/terraform/${stack}}"   # TF_STACK_DIR: tests only
cmd="${1:-}"
HISTORY="${ROOT}/.cache/state-history/${stack}"
KEEP=20

case "${cmd}" in
  output|show|validate|fmt|version|providers|graph|"") exec terraform -chdir="${dir}" "$@" ;;
esac

[[ -f "${ROOT}/.cache/garage/credentials" ]] || {
  echo "no .cache/garage/credentials: run make garage first (writes the Terraform S3 key)" >&2; exit 1; }

mkdir -p "${ROOT}/.cache"
exec 9>"${ROOT}/.cache/terraform.lock"
if ! flock -n 9; then
  echo "another Terraform run holds .cache/terraform.lock; waiting (up to ${TF_LOCK_WAIT:-900}s)…" >&2
  flock -w "${TF_LOCK_WAIT:-900}" 9 || { echo "gave up waiting for .cache/terraform.lock" >&2; exit 1; }
fi

terraform -chdir="${dir}" "$@"
rc=$?

case "${cmd}" in
  apply|destroy|import|state|taint|untaint|refresh|init|force-unlock) ;;
  *) exit "${rc}" ;;
esac

# history snapshot, also after a failed apply: a partial apply changes state too
umask 077
mkdir -p "${HISTORY}"
tmp="$(mktemp)"; trap 'rm -f "${tmp}"' EXIT
if terraform -chdir="${dir}" state pull > "${tmp}" 2>/dev/null && [[ -s "${tmp}" ]]; then
  sum="$(sha256sum "${tmp}" | cut -c1-12)"
  last="$(ls -1 "${HISTORY}" 2>/dev/null | tail -1)"
  if [[ "${last}" != *"-${sum}.tfstate.age" ]]; then
    recipient="$(age-keygen -y "${ROOT}/.cache/age/key.txt")"
    age -r "${recipient}" -o "${HISTORY}/$(date +%Y%m%d-%H%M%S)-${sum}.tfstate.age" "${tmp}"
    ls -1 "${HISTORY}" | head -n -"${KEEP}" | sed "s#^#${HISTORY}/#" | xargs -r rm -f
  fi
fi
exit "${rc}"
