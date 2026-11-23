#!/usr/bin/env bash
# Start the lab VMs after `make shutdown`, in dependency order: OPNsense (DHCP/DNS/NAT for everything), then
# the control plane, then the workers. Also run it after a host power-on: the VMs autostart, but only this
# script wakes the databases that `make shutdown` hibernated. Safe to run on a lab that's already up.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VIRSH=(virsh -c qemu+ssh://macpro/system)
WAN_IP="$(cat "${ROOT}/.cache/host/opnsense-wan.ip" 2>/dev/null)"

start() { [[ "$("${VIRSH[@]}" domstate "$1" 2>/dev/null | head -1)" == "running" ]] && echo "  $1: already running" || { "${VIRSH[@]}" start "$1" >/dev/null && echo "  $1: started"; }; }

echo ">> OPNsense"
start opnsense
for _ in $(seq 1 36); do ping -c1 -W2 "${WAN_IP}" >/dev/null 2>&1 && { echo "  WAN ${WAN_IP} up"; break; }; sleep 5; done
"${ROOT}/scripts/route-ensure.sh"   # gone after a workstation reboot; sudo asks only if it's missing

nodes_json="$(terraform -chdir="${ROOT}/terraform/host" output -json talos_nodes)"
echo ">> control plane, then workers"
for role in controlplane worker; do
  for name in $(python3 -c "import json,sys; [print(k) for k,v in sorted(json.load(sys.stdin).items()) if v['role']=='${role}']" <<<"${nodes_json}"); do
    start "${name}"
  done
  [[ "${role}" == controlplane ]] && sleep 30
done
echo ">> waiting for every Talos API and all nodes Ready (up to 10 min)"
export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"
mapfile -t IPS < <(python3 -c 'import json,sys; [print(v["ip"]) for v in json.load(sys.stdin).values()]' <<<"${nodes_json}")
deadline=$((SECONDS + 600))
for ip in "${IPS[@]}"; do
  until timeout 3 bash -c "</dev/tcp/${ip}/50000" 2>/dev/null; do
    ((SECONDS > deadline)) && { echo "  ${ip}: Talos API still down after 10 min" >&2; exit 1; }; sleep 5
  done
  echo "  ${ip}: Talos API up"
done
until kubectl wait --for=condition=Ready nodes --all --timeout=10s >/dev/null 2>&1; do
  ((SECONDS > deadline)) && { echo "  nodes not Ready after 10 min" >&2; kubectl get nodes >&2; exit 1; }; sleep 5
done
kubectl get nodes
# make shutdown's drain leaves every node cordoned. Talos uncordons only at the end of its last boot phase,
# ~8 min after the node is Ready (2026-11-23: startEverything 7m49s), and until then nothing schedules: no
# Argo CD, no CNPG webhook. Uncordoning here is safe: the cordon is our own, from the drain.
echo ">> uncordon (make shutdown's drain cordoned the nodes)"
kubectl uncordon $(kubectl get nodes -o name) | sed 's/^/  /'
echo ">> databases: wake from hibernation (make shutdown hibernates them)"
# Nodes Ready isn't enough right after a host boot: every change to a Cluster goes through CNPG's admission
# webhook, which only answers once the operator pod is up. So retry for up to 5 min, and fail loudly
# (2026-11-23: the wake timed out on the webhook, the script said "Lab is up" and pg-demo stayed hibernated).
deadline=$((SECONDS + 300))
wake_failed=()
until DBS_RAW="$(kubectl get clusters.postgresql.cnpg.io -A --request-timeout=15s \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations.cnpg\.io/hibernation}{"\n"}{end}' 2>/dev/null)"; do
  ((SECONDS > deadline)) && { wake_failed+=("(could not list the CNPG clusters)"); break; }
  sleep 5
done
mapfile -t DBS < <(grep . <<<"${DBS_RAW:-}")
for line in "${DBS[@]}"; do
  read -r c hib <<<"${line}"
  if [[ "${hib}" != on ]]; then echo "  ${c}: not hibernated"; continue; fi
  until err="$(kubectl -n "${c%/*}" annotate cluster "${c#*/}" cnpg.io/hibernation- --request-timeout=15s 2>&1 >/dev/null)"; do
    ((SECONDS > deadline)) && { echo "  ${c}: ${err}" >&2; wake_failed+=("${c}"); continue 2; }
    echo "  ${c}: CNPG not answering yet, retrying"; sleep 10
  done
  echo "  ${c}: waking up"
done
echo
if ((${#wake_failed[@]})); then
  echo "Lab VMs are up, but these databases are still hibernated: ${wake_failed[*]}" >&2
  echo "Run make start again, or: kubectl -n databases annotate cluster --all cnpg.io/hibernation-" >&2
  exit 1
fi
echo "Lab is up after $((SECONDS / 60)) min. Apps settle within a few minutes; check with: make verify"
