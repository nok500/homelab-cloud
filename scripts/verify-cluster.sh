#!/usr/bin/env bash
# Phase 2 acceptance checks, run from the admin workstation after `make up && make route`:
#   1. Talos: every node answers its API, has time from OPNsense, and the guest agent is up.
#   2. Kubernetes: all nodes Ready, no kube-proxy, CoreDNS resolves in-cluster and external names.
#   3. Cilium: agents and operator healthy, LB pool has IPs, L2 announcement policy present.
#   4. Argo CD: every Application Synced + Healthy.
#   5. Gateway: programmed on its fixed IP, argocd.lab.macpro answers through it.
# Waits (bounded) for things that converge after bootstrap, so it can run straight after `make up`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.cache/cluster/kubeconfig"   # always the lab cluster, never the caller's context
export TALOSCONFIG="${ROOT}/.cache/cluster/talosconfig"
export PATH="${ROOT}/.tools/bin:${PATH}"

GATEWAY_IP="10.10.1.200"
ARGOCD_HOST="argocd.lab.macpro"

pass=0 fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi; }
# retry <tries> <delay> <cmd...>: for state that converges after bootstrap
retry() { local n="$1" d="$2"; shift 2; for _ in $(seq 1 "${n}"); do "$@" && return 0; sleep "${d}"; done; return 1; }

[[ -f "${KUBECONFIG}" && -f "${TALOSCONFIG}" ]] || { echo "no cluster credentials in .cache/cluster; run make up" >&2; exit 1; }

nodes_json="$(terraform -chdir="${ROOT}/terraform/host" output -json talos_nodes)"
mapfile -t NODES < <(python3 -c 'import json,sys; [print(k, v["ip"]) for k, v in sorted(json.load(sys.stdin).items())]' <<<"${nodes_json}")

echo "1. Talos"
for entry in "${NODES[@]}"; do
  read -r name ip <<<"${entry}"
  check "${name} (${ip}) Talos API" talosctl -n "${ip}" version
  check "${name} NTP synced (OPNsense)" sh -c "talosctl -n ${ip} get timestatus -o jsonpath='{.spec.synced}' | grep -qx true"
  check "${name} qemu-guest-agent running" sh -c "talosctl -n ${ip} service ext-qemu-guest-agent | grep -q 'STATE.*Running'"
done

echo "2. Kubernetes"
check "all ${#NODES[@]} nodes Ready" retry 30 10 kubectl wait --for=condition=Ready nodes --all --timeout=5s
count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
[[ "${count}" -eq "${#NODES[@]}" ]] && ok "node count ${count}" || bad "node count ${count} (want ${#NODES[@]})"
if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then bad "no kube-proxy (Cilium replaces it)"; else ok "no kube-proxy (Cilium replaces it)"; fi
check "CoreDNS available" kubectl -n kube-system rollout status deploy/coredns --timeout=60s
# Restricted-PSA-compliant throwaway pod; retried because CoreDNS caches the SERVFAILs it gets while
# the VPC resolver is still warming up right after a rebuild.
DNS_POD_OVERRIDES='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"dns","image":"busybox:1.37.0","command":["sh","-c","nslookup kubernetes.default.svc.cluster.local && nslookup deb.debian.org"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
pod_dns() {
  dns_out="$(kubectl run "verify-dns-$$" --rm -i --restart=Never --quiet --image=busybox:1.37.0 \
    --overrides="${DNS_POD_OVERRIDES}" 2>&1)"
  grep -q "deb.debian.org" <<<"${dns_out}" && ! grep -qi "can't find\|NXDOMAIN\|SERVFAIL" <<<"${dns_out}"
}
if retry 6 15 pod_dns; then
  ok "pod resolves cluster and external names"
else
  bad "pod DNS: ${dns_out//$'\n'/ }"
fi

echo "3. Cilium"
check "cilium agents ready" kubectl -n kube-system rollout status ds/cilium --timeout=120s
check "cilium operator ready" kubectl -n kube-system rollout status deploy/cilium-operator --timeout=120s
agent="$(kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null | head -1)"
check "cilium status (KubeProxyReplacement True)" sh -c "kubectl -n kube-system exec ${agent} -c cilium-agent -- cilium-dbg status | grep -q 'KubeProxyReplacement:.*True'"
pool_free() { kubectl get ciliumloadbalancerippool private -o jsonpath='{.status.conditions[?(@.type=="cilium.io/IPsAvailable")].message}' | awk '$1 > 0 {f=1} END {exit !f}'; }
check "LB IP pool private has free IPs" retry 12 5 pool_free
check "L2 announcement policy present" kubectl get ciliuml2announcementpolicies.cilium.io -o name

echo "4. Argo CD"
apps_ok() {
  kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' \
    2>/dev/null | awk 'NF {n++; if ($2!="Synced" || $3!="Healthy") bad++} END {exit !(n > 0 && bad == 0)}'
}
if retry 30 10 apps_ok; then
  ok "all Applications Synced/Healthy ($(kubectl -n argocd get applications --no-headers | wc -l))"
else
  bad "Applications not all Synced/Healthy:"
  kubectl -n argocd get applications 2>&1 | sed 's/^/       /'
fi

echo "5. Gateway"
gw_ready() { kubectl -n gateway get gateway lab -o jsonpath='{.status.addresses[0].value} {.status.conditions[?(@.type=="Programmed")].status}' | grep -qx "${GATEWAY_IP} True"; }
check "Gateway lab programmed on ${GATEWAY_IP}" retry 18 10 gw_ready
check "HTTP ${ARGOCD_HOST} via ${GATEWAY_IP} (no DNS needed)" \
  retry 6 10 curl -fsS -m 5 -o /dev/null --resolve "${ARGOCD_HOST}:80:${GATEWAY_IP}" "http://${ARGOCD_HOST}/"
if getent hosts "${ARGOCD_HOST}" | grep -q "^${GATEWAY_IP} "; then
  ok "${ARGOCD_HOST} resolves to ${GATEWAY_IP} (AdGuard rewrite)"
else
  bad "${ARGOCD_HOST} does not resolve to ${GATEWAY_IP}: check the AdGuard *.lab.macpro rewrite"
fi

echo
printf '%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
