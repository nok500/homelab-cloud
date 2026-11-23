#!/usr/bin/env bash
# terraform/identity (ADR 0012): the Keycloak realm, users, groups and clients, as Terraform.
#   scripts/identity.sh <terraform args...>   e.g. init, plan, apply -auto-approve
#   scripts/identity.sh forget                drop everything from the state (make destroy: the realm dies
#                                             with the cluster, so there is nothing left to destroy)
# Passes the seeded credentials as TF_VAR_* (decrypted from the SOPS OpenBao seed into the environment only),
# waits for Keycloak to answer, and runs Terraform through scripts/tf.sh (lock + encrypted state history).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
TF=("${ROOT}/scripts/tf.sh" identity)
URL="https://sso.lab.macpro"
ROOT_CA="${ROOT}/k8s/platform/step-ca/config/root_ca.crt"

if [[ "${1:-}" == forget ]]; then
  mapfile -t addrs < <("${TF[@]}" state list 2>/dev/null || true)
  if ((${#addrs[@]})); then "${TF[@]}" state rm "${addrs[@]}" >/dev/null && echo "identity state: dropped ${#addrs[@]} resources"
  else echo "identity state: already empty"; fi
  exit 0
fi

seed() {
  SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt" sops --decrypt --extract "[\"data\"][\"$1\"]" \
    "${ROOT}/k8s/platform/openbao/seed.enc.yaml" | base64 -d
}
TF_VAR_admin_password="$(seed keycloak-admin-password)"
TF_VAR_labadmin_password="$(seed keycloak-labadmin-password)"
TF_VAR_argocd_client_secret="$(seed keycloak-argocd-client-secret)"
TF_VAR_harbor_client_secret="$(seed keycloak-harbor-client-secret)"
TF_VAR_grafana_client_secret="$(seed keycloak-grafana-client-secret)"
export TF_VAR_admin_password TF_VAR_labadmin_password TF_VAR_argocd_client_secret TF_VAR_harbor_client_secret \
  TF_VAR_grafana_client_secret

case "${1:-}" in
  plan|apply|refresh|import)
    deadline=$((SECONDS + 600))
    until curl -fsS -m 10 -o /dev/null --cacert "${ROOT_CA}" "${URL}/realms/master/.well-known/openid-configuration"; do
      ((SECONDS > deadline)) && { echo "Keycloak at ${URL} not answering after 10 min" >&2; exit 1; }
      echo "  waiting for Keycloak at ${URL}"; sleep 10
    done ;;
esac
exec "${TF[@]}" "$@"
