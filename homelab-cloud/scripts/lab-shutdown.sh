#!/usr/bin/env bash
# Safe shutdown of the lab, in dependency order (docs/runbooks/power.md):
#   0. databases:      CNPG hibernation (clean PostgreSQL stop; its PDB would block the drain otherwise)
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

export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"
step "0/3 databases: hibernate (clean PostgreSQL stop before the drain)"
# CNPG's PodDisruptionBudget allows 0 disruptions for a primary. Once the other worker is gone it can't move,
# so talosctl's drain would wait until the timeout and the VM would be forced off mid-write (2026-11-21).
# Hibernation shuts PostgreSQL down cleanly and removes the pods; the volumes stay. make start wakes them.
mapfile -t DBS < <(kubectl get clusters.postgresql.cnpg.io -A --request-timeout=10s \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
if ((${#DBS[@]})); then
  for c in "${DBS[@]}"; do   # retried: the annotation goes through CNPG's webhook, which can be slow to answer
    for try in 1 2 3 4 5 6; do
      kubectl -n "${c%/*}" annotate cluster "${c#*/}" cnpg.io/hibernation=on --overwrite --request-timeout=15s >/dev/null \
        && { echo "  ${c}: hibernating"; break; }
      ((try == 6)) && echo "  ${c}: could not hibernate it (CNPG webhook not answering?), continuing" >&2
      sleep 5
    done
  done
  deadline=$((SECONDS + 180))
  for c in "${DBS[@]}"; do
    until [[ -z "$(kubectl -n "${c%/*}" get pods -l "cnpg.io/cluster=${c#*/}" -o name 2>/dev/null)" ]]; do
      ((SECONDS > deadline)) && { echo "  ${c}: pods still there after 3 min, continuing (the drain may hit its timeout)" >&2; break; }
      sleep 3
    done
  done
  echo "  databases stopped"
else
  echo "  no CNPG clusters (or the API isn't reachable): nothing to hibernate"
fi

step "1/3 workers"
talos_down "${WORKERS[@]}"

step "2/3 control plane"
talos_down "${CPS[@]}"

step "3/3 OPNsense"
if [[ "$(state opnsense)" == "running" ]]; then "${VIRSH[@]}" shutdown opnsense >/dev/null; fi
wait_off 120 opnsense

echo
echo "Lab is off. Bring it back with: make start (after a host power-on too: the VMs autostart, but only make start wakes the databases)."

if [[ "${POWEROFF:-0}" == 1 ]]; then
  step "host: powering off the Mac Pro (sudo password on macpro)"
  ssh -t macpro sudo systemctl poweroff
fi
