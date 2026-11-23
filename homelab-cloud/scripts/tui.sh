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
# From a plain terminal it's a separate `homelab` session you attach to; detaching (prefix d) leaves
# everything running, including a build in progress. From inside tmux the boxes are built as splits of your
# current window instead (your pane stays, at the bottom): running it again there focuses the TUI, and
# make tui-kill closes the boxes again. A build already running in the homelab session wins: you're
# switched to it rather than getting a second TUI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${TUI_SESSION:-homelab}"
P="${ROOT}/scripts/tui"
STATUS_FILE="${ROOT}/.cache/tui/up.status"
MODE="${1:-}"

command -v tmux >/dev/null || { echo "tmux not found: sudo pacman -S tmux" >&2; exit 1; }

if [[ "${MODE}" == "--kill" ]]; then
  if [[ -n "${TMUX:-}" ]]; then   # the TUI embedded in this window: close its boxes, keep your pane
    win=$(tmux display -p -t "${TMUX_PANE}" '#{window_id}')
    mapfile -t boxes < <(tmux list-panes -t "${win}" -F '#{pane_id} #{@tui}' | awk '$2==1{print $1}')
    if ((${#boxes[@]})); then
      for b in "${boxes[@]}"; do tmux kill-pane -t "${b}"; done
      tmux set -wu -t "${win}" @tui_talos_pane; tmux set-hook -wu -t "${win}" window-resized
      for o in pane-border-status pane-border-format pane-border-lines pane-active-border-style allow-set-title; do
        tmux set -wu -t "${win}" "${o}"
      done
      echo "closed the TUI in this window"
    fi
  fi
  tmux kill-session -t "${SESSION}" 2>/dev/null && echo "closed ${SESSION}" || echo "no ${SESSION} session"
  exit 0
fi

talos_cmd="${P}/talos-pane.sh"
[[ "${MODE}" == "--up" ]] && talos_cmd="${P}/talos-pane.sh --up"
build_running() { [[ "$(cat "${STATUS_FILE}" 2>/dev/null)" == running ]]; }

# The six boxes, grown out of ${1}: a pane already running `panel.py status`. Every box is tagged @tui (so
# --kill can find them) and titled. Prints the talos pane's id.
build_layout() {
  local status="$1" host pods vms talos nodes
  host=$(tmux split-window -v -t "${status}" -l 5 -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py host")
  tmux resize-pane -t "${status}" -y 1   # status keeps 1 line; everything else goes below host
  pods=$(tmux split-window -v -t "${host}" -l '85%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py pods")
  vms=$(tmux split-window -h -t "${host}" -l '50%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py vms")
  talos=$(tmux split-window -v -t "${pods}" -l '55%' -c "${ROOT}" -P -F '#{pane_id}' "${talos_cmd}")
  nodes=$(tmux split-window -h -t "${pods}" -l '30%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py nodes")
  tmux resize-pane -t "${host}" -y 6
  for pair in "${status}:STATUS" "${host}:CPU | RAM | TEMP" "${vms}:QEMU VMs" "${pods}:PODS" \
              "${nodes}:NODES" "${talos}:TALOS DASHBOARD"; do
    tmux select-pane -t "${pair%%:*}" -T "${pair#*:}"
    tmux set -p -t "${pair%%:*}" @tui 1
  done
  echo "${talos}"
}

# window look, shared by both modes (window options only: a user's own session settings stay untouched)
style_window() {
  local w="$1"
  tmux set -w -t "${w}" pane-border-status top
  tmux set -w -t "${w}" pane-border-format ' #{pane_title} '
  tmux set -w -t "${w}" pane-border-lines single
  tmux set -w -t "${w}" pane-active-border-style 'fg=colour39'
  tmux set -w -t "${w}" allow-set-title off
}

pane_alive() { [[ -n "$1" ]] && tmux display -p -t "$1" '#{pane_id}' >/dev/null 2>&1; }

# ---- inside tmux: the TUI goes into the current window as splits (your pane stays, at the bottom) ----
if [[ -n "${TMUX:-}" ]]; then
  win=$(tmux display -p -t "${TMUX_PANE}" '#{window_id}')
  talos=$(tmux show -w -v -q -t "${win}" @tui_talos_pane)
  if pane_alive "${talos}"; then                     # this window already has the TUI
    if [[ "${MODE}" == "--up" ]]; then
      if build_running; then echo "a make up is already running in the TUI" >&2
      else tmux respawn-pane -k -t "${talos}" "${talos_cmd}"; fi
    fi
    tmux select-pane -t "${talos}"
    exit 0
  fi
  if build_running && tmux has-session -t "${SESSION}" 2>/dev/null; then
    echo "a make up is running in the ${SESSION} session: switching to it" >&2
    tmux switch-client -t "${SESSION}"
    exit 0
  fi
  status=$(tmux split-window -v -b -f -t "${TMUX_PANE}" -l '85%' -c "${ROOT}" -P -F '#{pane_id}' "${P}/panel.py status")
  # tmux rescales every box when the window changes size: pin the two fixed-height rows each time
  talos=$(build_layout "${status}")
  FIX="resize-pane -t ${status} -y 1 ; resize-pane -t $(tmux list-panes -t "${win}" -F '#{pane_id} #{pane_title}' | awk '$2=="CPU"{print $1}') -y 6"
  tmux set-hook -w -t "${win}" window-resized "${FIX}"
  tmux set -w -t "${win}" @tui_talos_pane "${talos}"
  style_window "${win}"
  tmux select-pane -t "${talos}"
  exit 0
fi

# ---- plain terminal: a separate session, attached here ----
if tmux has-session -t "${SESSION}" 2>/dev/null; then
  if [[ "${MODE}" == "--up" ]]; then
    if build_running; then
      echo "a make up is already running in the TUI: attaching to it" >&2
    else
      tmux respawn-pane -k -t "$(tmux show -t "${SESSION}" -v @talos_pane)" "${talos_cmd}"
    fi
  fi
else
  cols=$(tput cols 2>/dev/null || echo 200) lines=$(tput lines 2>/dev/null || echo 60)
  status=$(tmux new-session -d -s "${SESSION}" -x "${cols}" -y "${lines}" -c "${ROOT}" -P -F '#{pane_id}' \
    "${P}/panel.py status")
  talos=$(build_layout "${status}")
  host=$(tmux list-panes -t "${SESSION}" -F '#{pane_id} #{pane_title}' | awk '$2=="CPU"{print $1}')
  fix="resize-pane -t ${status} -y 1 ; resize-pane -t ${host} -y 6"
  tmux set-hook -t "${SESSION}" client-attached "${fix}"
  tmux set-hook -t "${SESSION}" client-resized "${fix}"
  tmux set -t "${SESSION}" @talos_pane "${talos}"
  tmux set -t "${SESSION}" mouse on
  tmux set -t "${SESSION}" status-style 'bg=colour236,fg=colour250'
  tmux set -t "${SESSION}" status-left " homelab-cloud "
  tmux set -t "${SESSION}" status-left-length 20
  tmux set -t "${SESSION}" status-right " prefix d: detach (make tui: back) · prefix z: zoom box · click: focus "
  tmux set -t "${SESSION}" status-right-length 80
  style_window "${SESSION}"
  tmux set -w -t "${SESSION}" window-size latest
  tmux select-pane -t "${talos}"
fi

tmux attach -t "${SESSION}"

# back here after a detach or the session closing: report the build if this run started one
if [[ "${MODE}" == "--up" && -f "${STATUS_FILE}" ]]; then
  read -r rc took log <"${STATUS_FILE}" || true
  case "${rc}" in
    running) echo "make up is still running in the TUI (make tui to reattach)" ;;
    0) echo "make up finished in ${took} (log: ${log#"${ROOT}"/})"; echo; "${ROOT}/scripts/logins.sh" --if-tty ;;
    *) echo "make up failed (exit ${rc}) after ${took}; log: ${log}" >&2; exit "${rc}" ;;
  esac
fi
