#!/usr/bin/env bash
# Lab TUI: a tmux session laid out like docs/img/tui-layout.png (docs/runbooks/monitoring.md).
#   scripts/tui.sh          attach to the session, creating it if needed       (make tui)
#   scripts/tui.sh --up     same, and run the build in the bottom box first    (make up, from a terminal)
#   scripts/tui.sh --kill   close the session                                  (make tui-kill)
#
#   ┌ status dots: talos kubernetes cilium argocd gateway storage secrets ┐
#   ├ CPU | RAM | TEMP (Mac Pro) ─────────┬ QEMU VMs ────────────────────┤
#   ├ PODS ───────────────────────────────┬ NODES ───────┤
#   ├ TALOS DASHBOARD (or the make up build while it runs) ──────────────┤
#
# Detaching (prefix d) leaves everything running, including a build in progress.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${TUI_SESSION:-homelab}"
P="${ROOT}/scripts/tui"
STATUS_FILE="${ROOT}/.cache/tui/up.status"
MODE="${1:-}"

command -v tmux >/dev/null || { echo "tmux not found: sudo pacman -S tmux" >&2; exit 1; }

if [[ "${MODE}" == "--kill" ]]; then
  tmux kill-session -t "${SESSION}" 2>/dev/null && echo "closed ${SESSION}" || echo "no ${SESSION} session"
  exit 0
fi

talos_cmd="${P}/talos-pane.sh"
[[ "${MODE}" == "--up" ]] && talos_cmd="${P}/talos-pane.sh --up"

if tmux has-session -t "${SESSION}" 2>/dev/null; then
  if [[ "${MODE}" == "--up" ]]; then
    if [[ "$(cat "${STATUS_FILE}" 2>/dev/null)" == running ]]; then
      echo "a make up is already running in the TUI: attaching to it" >&2
    else
      tmux respawn-pane -k -t "$(tmux show -t "${SESSION}" -v @talos_pane)" "${talos_cmd}"
    fi
  fi
else
  cols=$(tput cols 2>/dev/null || echo 200) lines=$(tput lines 2>/dev/null || echo 60)
  status=$(tmux new-session -d -s "${SESSION}" -x "${cols}" -y "${lines}" -c "${ROOT}" -P -F '#{pane_id}' \
    "${P}/panel.py status")
  host=$(tmux split-window -v -t "${status}" -l 5 -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py host")
  # status keeps 1 line; everything else goes below host
  tmux resize-pane -t "${status}" -y 1
  pods=$(tmux split-window -v -t "${host}" -l '85%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py pods")
  vms=$(tmux split-window -h -t "${host}" -l '50%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py vms")
  talos=$(tmux split-window -v -t "${pods}" -l '55%' -c "${ROOT}" -P -F '#{pane_id}' "${talos_cmd}")
  nodes=$(tmux split-window -h -t "${pods}" -l '30%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py nodes")
  # tmux rescales every box when a client attaches or resizes: pin the two fixed-height rows each time
  fix="resize-pane -t ${status} -y 1 ; resize-pane -t ${host} -y 6"
  tmux set-hook -t "${SESSION}" client-attached "${fix}"
  tmux set-hook -t "${SESSION}" client-resized "${fix}"
  tmux resize-pane -t "${host}" -y 6

  for pair in "${status}:STATUS" "${host}:CPU | RAM | TEMP" "${vms}:QEMU VMs" "${pods}:PODS" \
              "${nodes}:NODES" "${talos}:TALOS DASHBOARD"; do
    tmux select-pane -t "${pair%%:*}" -T "${pair#*:}"
  done
  tmux set -t "${SESSION}" @talos_pane "${talos}"
  tmux set -t "${SESSION}" mouse on
  tmux set -t "${SESSION}" status-style 'bg=colour236,fg=colour250'
  tmux set -t "${SESSION}" status-left " homelab-cloud "
  tmux set -t "${SESSION}" status-left-length 20
  tmux set -t "${SESSION}" status-right " prefix d: detach (make tui: back) · prefix z: zoom box · click: focus "
  tmux set -t "${SESSION}" status-right-length 80
  tmux set -w -t "${SESSION}" pane-border-status top
  tmux set -w -t "${SESSION}" pane-border-format ' #{pane_title} '
  tmux set -w -t "${SESSION}" pane-border-lines single
  tmux set -w -t "${SESSION}" pane-active-border-style 'fg=colour39'
  tmux set -w -t "${SESSION}" allow-set-title off
  tmux set -w -t "${SESSION}" window-size latest
  tmux select-pane -t "${talos}"
fi

if [[ -n "${TMUX:-}" ]]; then
  tmux switch-client -t "${SESSION}"
  exit 0
fi
tmux attach -t "${SESSION}"

# back here after a detach or the session closing: report the build if this run started one
if [[ "${MODE}" == "--up" && -f "${STATUS_FILE}" ]]; then
  read -r rc took log <"${STATUS_FILE}" || true
  case "${rc}" in
    running) echo "make up is still running in the TUI (make tui to reattach)" ;;
    0) echo "make up finished in ${took} (log: ${log#"${ROOT}"/})" ;;
    *) echo "make up failed (exit ${rc}) after ${took}; log: ${log}" >&2; exit "${rc}" ;;
  esac
fi
