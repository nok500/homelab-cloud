#!/usr/bin/env bash
# Every login the lab has, one per line: what, URL, user, password (make logins). The passwords come from the
# SOPS files in Git (decrypted with .cache/age/key.txt) or, for Argo CD's local admin, from the cluster.
# Prints secrets to the terminal: don't run it into a shared log. A source that can't be read shows as n/a
# (e.g. the cluster is down), the rest still print.
# --if-tty: print only to a terminal (make up's last step), else just say where to find them, so the
# passwords never land in a pipe, a CI log or the make up log file.
set -uo pipefail

if [[ "${1:-}" == --if-tty && ! -t 1 ]]; then
  echo "Lab logins: make logins (not printed here: output isn't a terminal)"; exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.tools/bin:${PATH}"
export SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt"
export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"
SEED="${ROOT}/k8s/platform/openbao/seed.enc.yaml"
GARAGE="${ROOT}/host/garage/secrets.enc.yaml"

seed() { sops --decrypt --extract "[\"data\"][\"$1\"]" "${SEED}" 2>/dev/null | base64 -d 2>/dev/null; }
garage() { sops --decrypt --extract "[\"stringData\"][\"$1\"]" "${GARAGE}" 2>/dev/null; }
argocd_admin() {
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' --request-timeout=5s \
    2>/dev/null | base64 -d 2>/dev/null
}

rows=(
  "Argo CD (SSO: LOG IN VIA KEYCLOAK)|https://argocd.lab.macpro|labadmin|$(seed keycloak-labadmin-password)"
  "Argo CD local admin (break-glass)|https://argocd.lab.macpro|admin|$(argocd_admin)"
  "Keycloak admin console (realm master)|https://sso.lab.macpro/admin|admin|$(seed keycloak-admin-password)"
  "Keycloak account (realm lab)|https://sso.lab.macpro/realms/lab/account|labadmin|$(seed keycloak-labadmin-password)"
  "OpenBao (method Username)|https://bao.lab.macpro|admin|$(seed admin-password)"
  "Garage UI|https://s3.lab.macpro:3909|admin|$(garage garage_ui_admin_password)"
)

printf '%-38s %-42s %-9s %s\n' WHAT URL USER PASSWORD
for r in "${rows[@]}"; do
  IFS='|' read -r what url user pass <<<"${r}"
  printf '%-38s %-42s %-9s %s\n' "${what}" "${url}" "${user}" "${pass:-n/a}"
done
