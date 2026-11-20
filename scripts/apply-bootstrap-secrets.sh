#!/usr/bin/env bash
# Apply the SOPS-encrypted bootstrap secrets (k8s/**/*.enc.yaml) to the lab cluster.
# These are the few secrets Argo CD can't get from anywhere else yet; from Phase 3 milestone 3 they
# come from OpenBao via External Secrets. Needs the age key in .cache/age/key.txt (see docs/runbooks/pki.md).
# Idempotent; called by bootstrap-cluster.sh, safe to run on its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"
export SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt"

[[ -f "${SOPS_AGE_KEY_FILE}" ]] || { echo "missing ${SOPS_AGE_KEY_FILE} (restore it from backup; docs/runbooks/pki.md)" >&2; exit 1; }

mapfile -t files < <(cd "${ROOT}" && git ls-files '*.enc.yaml')
for f in "${files[@]}"; do
  echo "   ${f}"
  plain="$(sops --decrypt "${ROOT}/${f}")"
  # namespaces first: these secrets are created before Argo CD syncs the apps that own the namespaces
  python3 -c 'import sys, yaml; [print(d["metadata"]["namespace"]) for d in yaml.safe_load_all(sys.stdin) if d]' <<<"${plain}" \
    | sort -u | while read -r ns; do
        kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      done
  kubectl apply -f - <<<"${plain}"
done
