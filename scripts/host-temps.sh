#!/usr/bin/env bash
# Print CPU package/core temperatures and fan speed of the lab host.
# The Mac Pro 2013 has a single shared heatsink and a history of thermal issues,
# so check this after bringing up new VMs or running heavy CI.
#   usage: scripts/host-temps.sh [--watch]
set -euo pipefail
HOST="${LAB_HOST:-192.168.8.207}"
WARN=80

read_temps() {
  ssh -o BatchMode=yes "${HOST}" \
    "sensors coretemp-isa-0000; sensors 2>/dev/null | grep -iE 'rpm'; cut -d' ' -f1-3 /proc/loadavg" |
    awk -v warn="${WARN}" '
      /Package|Core/ { match($0, /:[ \t]*\+[0-9.]+/); t=substr($0, RSTART, RLENGTH); sub(/^:[ \t]*\+/, "", t); printf "%-14s %5.1f C%s\n", $1" "$2, t, (t+0 >= warn ? "  <-- HOT" : "") }
      /RPM/          { print "fan           ", $3, "RPM" }
      /^[0-9.]+ /    { print "loadavg       ", $0 }'
}

if [[ "${1:-}" == "--watch" ]]; then
  while true; do clear; date; read_temps; sleep 5; done
else
  read_temps
fi
