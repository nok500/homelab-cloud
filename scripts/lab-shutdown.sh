#!/usr/bin/env bash
# Safe shutdown of the lab, in dependency order (docs/runbooks/power.md):
#   1. workers:        talosctl shutdown (cordon + drain, then a clean OS shutdown)
#   2. control plane:  talosctl shutdown (etcd stops cleanly; nothing left to drain onto)
#   3. OPNsense:       ACPI shutdown via libvirt (FreeBSD honours it)
#   4. host (POWEROFF=1 only): sudo systemctl poweroff on the Mac Pro (asks for your sudo password)
# Talos ignores the ACPI power button, so a host shutdown on its own would hard-kill the nodes after a
# timeout (libvirt-guests) or immediately (without it). Each step waits until the VM is really off and only
# forces it off after a timeout, saying so.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export TALOSCONFIG="${ROOT}/.cache/cluster/talosconfig"
VIRSH=(virsh -c qemu+ssh://macpro/system)
TIMEOUT="${SHUTDOWN_TIMEOUT:-300}"   # seconds per step before forcing a VM off

step() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
state() { "${VIRSH[@]}" domstate "$1" 2>/dev/null | head -1; }

wait_off() { # <timeout> <domain...>: wait until every domain is shut off, force the stragglers
  local deadline=$((SECONDS + $1)); shift
  local pending=("$@")
  while ((${#pending[@]})); do
    local still=()
    for d in "${pending[@]}"; do [[ "$(state "$d")" == "shut off" ]] || still+=("$d"); done
    pending=("${still[@]+"${still[@]}"}")
    ((${#pending[@]})) || break
    if ((SECONDS > deadline)); then
      echo "  timeout: forcing off ${pending[*]}" >&2
      for d in "${pending[@]}"; do "${VIRSH[@]}" destroy "$d" >/dev/null; done
      break
    fi
    sleep 5
  done
  for d in "$@"; do echo "  ${d}: $(state "$d")"; done
}

nodes_json="$(terraform -chdir="${ROOT}/terraform/host" output -json talos_nodes 2>/dev/null)" \
  || { echo "no terraform/host state: is the lab built?" >&2; exit 1; }
mapfile -t WORKERS < <(python3 -c 'import json,sys; [print(k, v["ip"]) for k,v in sorted(json.load(sys.stdin).items()) if v["role"]=="worker"]' <<<"${nodes_json}")
mapfile -t CPS < <(python3 -c 'import json,sys; [print(k, v["ip"]) for k,v in sorted(json.load(sys.stdin).items()) if v["role"]=="controlplane"]' <<<"${nodes_json}")

talos_down() { # <"name ip" ...>
  local names=()
  for entry in "$@"; do
    read -r name ip <<<"${entry}"; names+=("${name}")
    if [[ "$(state "${name}")" != "running" ]]; then echo "  ${name}: already $(state "${name}")"; continue; fi
    # --wait=false: the API goes away mid-call; completion is tracked via libvirt below
    talosctl -n "${ip}" shutdown --wait=false >/dev/null 2>&1 \
      && echo "  ${name} (${ip}): cordon, drain, shut down" \
      || echo "  ${name} (${ip}): Talos API unreachable, will be forced off after the timeout" >&2
  done
  wait_off "${TIMEOUT}" "${names[@]}"
}

step "1/3 workers"
talos_down "${WORKERS[@]}"

step "2/3 control plane"
talos_down "${CPS[@]}"

step "3/3 OPNsense"
if [[ "$(state opnsense)" == "running" ]]; then "${VIRSH[@]}" shutdown opnsense >/dev/null; fi
wait_off 120 opnsense

echo
echo "Lab is off. Bring it back with: make start (or just power on the Mac Pro: VMs autostart)."

if [[ "${POWEROFF:-0}" == 1 ]]; then
  step "host: powering off the Mac Pro (sudo password on macpro)"
  ssh -t macpro sudo systemctl poweroff
fi
