#!/usr/bin/env bash
# One-time cluster bootstrap after `terraform -chdir=terraform/talos apply`:
#   Gateway API CRDs -> Cilium (nodes become Ready) -> Argo CD -> repo credential -> root app-of-apps.
# From then on Argo CD owns all of these (k8s/bootstrap/apps/*). Safe to re-run: everything is
# helm upgrade --install / kubectl apply, using the chart versions pinned in the Application files.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"   # always the lab cluster, never the caller's context
DEPLOY_KEY="${ROOT}/.cache/cluster/argocd-deploy-key"
REPO_URL="git@github.com:nok500/homelab-cloud.git"

step() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
# chart version = the targetRevision right after `chart: <name>` in the Application manifest
chart_version() { awk -v c="$2" '$1=="chart:" && $2==c {f=1} f && $1=="targetRevision:" {print $2; exit}' "$1"; }

CILIUM_VERSION="$(chart_version "${ROOT}/k8s/bootstrap/apps/cilium.yaml" cilium)"
ARGOCD_VERSION="$(chart_version "${ROOT}/k8s/bootstrap/apps/argocd.yaml" argo-cd)"
[[ -n "${CILIUM_VERSION}" && -n "${ARGOCD_VERSION}" ]] || { echo "could not read chart versions" >&2; exit 1; }

step "API server (etcd + kube-apiserver come up a few minutes after talos_machine_bootstrap)"
for i in $(seq 1 60); do
  kubectl get --raw /readyz >/dev/null 2>&1 && break
  [[ "${i}" -eq 60 ]] && { echo "API server not ready after 10 min" >&2; exit 1; }
  sleep 10
done
kubectl version -o json | python3 -c 'import json,sys; print("server", json.load(sys.stdin)["serverVersion"]["gitVersion"])'

step "Gateway API CRDs (before Cilium, which only enables its Gateway controller if they exist)"
kubectl apply --server-side -k "${ROOT}/k8s/platform/gateway-api"

step "Cilium ${CILIUM_VERSION}"
helm upgrade --install cilium cilium --repo https://helm.cilium.io --version "${CILIUM_VERSION}" \
  --namespace kube-system -f "${ROOT}/k8s/platform/cilium/values.yaml" --wait --timeout 15m
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o wide

step "Argo CD (chart ${ARGOCD_VERSION})"
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "${ARGOCD_VERSION}" \
  --namespace argocd --create-namespace -f "${ROOT}/k8s/bootstrap/argocd/values.yaml" --wait --timeout 15m

step "repository credential (read-only deploy key: stays a bootstrap secret, Argo CD needs it before OpenBao exists)"
[[ -f "${DEPLOY_KEY}" ]] || { echo "missing ${DEPLOY_KEY} (see docs/bootstrap.md)" >&2; exit 1; }
kubectl -n argocd create secret generic repo-homelab-cloud \
  --from-literal=type=git --from-literal=url="${REPO_URL}" --from-file=sshPrivateKey="${DEPLOY_KEY}" \
  --dry-run=client -o yaml | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

step "bootstrap secrets (SOPS: the OpenBao seed; everything else comes from OpenBao via External Secrets)"
"${ROOT}/scripts/apply-bootstrap-secrets.sh"

step "root app-of-apps"
kubectl apply -f "${ROOT}/k8s/bootstrap/root.yaml"

step "waiting for Argo CD to converge (every Application Synced + Healthy; up to 25 min)"
# Dependency chain after a rebuild: OpenBao -> secret store -> step-ca Secrets -> step-ca -> issuer -> wildcard
# cert -> Gateway HTTPS. Each link waits on its own retry backoff, so this takes ~10-15 min. Without this wait
# `make up` would return long before the lab is usable.
deadline=$((SECONDS + 1500))
while :; do
  pending="$(kubectl -n argocd get applications --no-headers 2>/dev/null | awk '$2!="Synced" || $3!="Healthy" {print $1 "(" $2 "/" $3 ")"}' | tr '\n' ' ')"
  count="$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l)"
  if [[ -z "${pending}" && "${count}" -gt 1 ]]; then echo "all ${count} Applications Synced/Healthy after $((SECONDS / 60)) min"; break; fi
  (( SECONDS > deadline )) && { echo "not converged after 25 min: ${pending}" >&2; exit 1; }
  printf '  %s pending: %s\n' "$(date +%H:%M:%S)" "${pending:-root app not synced yet}"
  sleep 30
done

echo
echo "Argo CD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
