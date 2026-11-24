#!/usr/bin/env bash
# Start Garage S3 on the Mac Pro host if it isn't running, then wait until https://s3.lab.macpro:3900 answers.
# make start and make up (via make init) run it first: Terraform state lives there (ADR 0010). Starts the
# containers as deployed (docker compose up -d in ~/homelab-garage); it never redeploys: that's make garage.
# 2026-11-24: after a host power-off and boot Docker left all three containers stopped, and make up failed
# at terraform init with an S3 timeout.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_IP="${LAB_HOST:-192.168.8.207}"
DIR="${GARAGE_DIR:-homelab-garage}"
S3="https://s3.lab.macpro:3900"
CA="${ROOT}/k8s/platform/step-ca/config/root_ca.crt"

# Caddy answers 502 while Garage is down, so only a real S3 answer counts (403: no credentials, as expected)
s3_up() {
  local code
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' --resolve "s3.lab.macpro:3900:${HOST_IP}" --cacert "${CA}" "${S3}/")"
  [[ "${code}" =~ ^(200|403)$ ]]
}

if s3_up; then echo "  ${S3}: up"; exit 0; fi
ssh -o BatchMode=yes -o ConnectTimeout=10 macpro "test -f ${DIR}/compose.yaml" \
  || { echo "  Garage isn't deployed on the host (no ~/${DIR}/compose.yaml): run make garage" >&2; exit 1; }
echo "  ${S3}: down, starting the containers on the host"
ssh -o BatchMode=yes macpro "cd ${DIR} && GARAGE_BIND_IP=${HOST_IP} docker compose up -d --quiet-pull" 2>&1 | sed 's/^/  /'
for _ in $(seq 1 30); do s3_up && { echo "  ${S3}: up"; exit 0; }; sleep 2; done
echo "  ${S3}: still not answering after 60 s; on the host: cd ~/${DIR} && docker compose ps; docker compose logs --tail 30" >&2
exit 1
