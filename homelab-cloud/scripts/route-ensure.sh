#!/usr/bin/env bash
# Make sure this workstation routes the lab CIDR via the OPNsense WAN (docs/runbooks/cluster-access.md).
# Runs `sudo ip route replace` only when the route is missing or points elsewhere, so sudo asks for your
# password only then (after every workstation reboot). Called by make up (after the host stage), make start
# (once OPNsense answers) and make route.
#   FORCE=1: set it even if it looks right (make route)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CIDR="${LAB_CIDR:-10.10.0.0/16}"
WAN_IP_FILE="${ROOT}/.cache/host/opnsense-wan.ip"

[[ -s "${WAN_IP_FILE}" ]] || { echo "no OPNsense WAN IP yet (${WAN_IP_FILE#"${ROOT}"/}): run make up" >&2; exit 1; }
wan="$(cat "${WAN_IP_FILE}")"

if [[ "${FORCE:-0}" != 1 ]] && ip route show "${CIDR}" | grep -q "via ${wan} "; then
  echo "route ${CIDR} via ${wan}: present"
  exit 0
fi

printf '\033[1m>> route %s via %s is missing: adding it (sudo asks for your password)\033[0m\n' "${CIDR}" "${wan}"
sudo ip route replace "${CIDR}" via "${wan}"
ip route show "${CIDR}"
