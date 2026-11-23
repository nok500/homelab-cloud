#!/usr/bin/env bash
# Bottom box of the lab TUI (scripts/tui.sh).
#   talos-pane.sh         talosctl dashboard for all nodes, restarted whenever it exits or the lab comes back
#   talos-pane.sh --up    first runs the build (make build) right here, then switches to the dashboard
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export TALOSCONFIG="${ROOT}/.cache/cluster/talosconfig"
STATUS_FILE="${ROOT}/.cache/tui/up.status"
LOG_DIR="${ROOT}/.cache/logs"
TARGET="${TUI_UP_TARGET:-build}"   # override only to test this script (e.g. TUI_UP_TARGET=plan, read-only)

if [[ "${1:-}" == "--up" ]]; then
  mkdir -p "${LOG_DIR}" "$(dirname "${STATUS_FILE}")"
  log="${LOG_DIR}/make-up-$(date +%Y%m%d-%H%M%S).log"
  echo "running" >"${STATUS_FILE}"
  start=${SECONDS}
  printf '\033[1m>> make up (log: %s)\033[0m\n' "${log#"${ROOT}"/}"
  # script(1) keeps a TTY for make (Terraform's yes/no prompt, colours) while still writing the log
  script -qefc "make -C '${ROOT}' ${TARGET}" "${log}"
  rc=$?
  took=$(((SECONDS - start) / 60))m$(((SECONDS - start) % 60))s
  echo "${rc} ${took} ${log}" >"${STATUS_FILE}"
  if ((rc == 0)); then
    printf '\n\033[32m✔ make up finished in %s.\033[0m Switching to the Talos dashboard in 10 s (Enter: now).\n' "${took}"
    read -r -t 10 _ || true
  else
    printf '\n\033[31m✘ make up failed (exit %s) after %s.\033[0m Log: %s\n' "${rc}" "${took}" "${log}"
    printf 'Fix it, then run make up again (it reuses this TUI). Enter: open the Talos dashboard anyway.\n'
    read -r _ || true
  fi
fi

while true; do
  nodes="$(terraform -chdir="${ROOT}/terraform/host" output -json talos_nodes 2>/dev/null \
    | python3 -c 'import json,sys; print(",".join(v["ip"] for v in json.load(sys.stdin).values()))' 2>/dev/null)"
  if [[ -z "${nodes}" || ! -f "${TALOSCONFIG}" ]]; then
    clear; echo "Talos dashboard: waiting for the lab (make up)…"; sleep 10; continue
  fi
  if ! talosctl -n "${nodes%%,*}" version --short >/dev/null 2>&1; then
    clear; echo "Talos dashboard: waiting for the Talos API on ${nodes}…"; sleep 5; continue
  fi
  talosctl dashboard -n "${nodes}"
  clear; echo "Talos dashboard exited; restarting in 5 s."; sleep 5
done
