#!/usr/bin/env bash
# Phase 2 acceptance checks, run from the admin workstation after `make up && make route`:
#   1. Talos: every node answers its API, has time from OPNsense, and the guest agent is up.
#   2. Kubernetes: all nodes Ready, no kube-proxy, CoreDNS resolves in-cluster and external names.
#   3. Cilium: agents and operator healthy, LB pool has IPs, L2 announcement policy present.
#   4. Argo CD: every Application Synced + Healthy.
#   5. Gateway + TLS: programmed on its fixed IP, step-ca issues the *.lab.macpro wildcard, HTTP redirects
#      to HTTPS, and argocd.lab.macpro serves a certificate that chains to the lab root.
#   6. Storage: the default StorageClass binds a PVC on a worker data disk and a pod can write to it.
#   7. Secrets: OpenBao initialized + unsealed, the ClusterSecretStore is valid, every ExternalSecret synced,
#      and the OpenBao UI answers on https://bao.lab.macpro.
#   8. Terraform state: Garage on the Mac Pro host is up, s3.lab.macpro resolves to it, its TLS verifies and has
#      more than 30 days left, and both stacks' state objects are in the tfstate bucket.
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
ROOT_CA="${ROOT}/k8s/platform/step-ca/config/root_ca.crt"
RESOLVE=(--resolve "${ARGOCD_HOST}:80:${GATEWAY_IP}" --resolve "${ARGOCD_HOST}:443:${GATEWAY_IP}")
check "step-ca ready" kubectl -n step-ca rollout status statefulset/step-ca --timeout=120s
issuer_ready() { kubectl get stepclusterissuer step-ca -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True; }
check "StepClusterIssuer step-ca Ready" retry 18 10 issuer_ready
cert_ready() { kubectl -n gateway get certificate lab-wildcard -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True; }
check "Certificate *.lab.macpro issued" retry 18 10 cert_ready
redirect="$(curl -sS -m 5 -o /dev/null -w '%{http_code} %{redirect_url}' "${RESOLVE[@]}" "http://${ARGOCD_HOST}/" 2>/dev/null)"
# Cilium writes the default port into Location (https://host:443/); equivalent for every client
[[ "${redirect}" =~ ^301\ https://${ARGOCD_HOST}(:443)?/ ]] && ok "HTTP redirects to HTTPS" || bad "HTTP redirect (got '${redirect}')"
check "HTTPS ${ARGOCD_HOST} verifies against the lab root" \
  retry 6 10 curl -fsS -m 5 -o /dev/null --cacert "${ROOT_CA}" "${RESOLVE[@]}" "https://${ARGOCD_HOST}/"
issuer="$(echo | openssl s_client -connect "${GATEWAY_IP}:443" -servername "${ARGOCD_HOST}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
[[ "${issuer}" == *"homelab-cloud Intermediate CA"* ]] && ok "served cert issued by the lab intermediate" || bad "served cert issuer: '${issuer}'"
if curl -fsS -m 5 -o /dev/null "${RESOLVE[@]}" "https://${ARGOCD_HOST}/" 2>/dev/null; then
  ok "this machine trusts the lab root (system store)"
else
  bad "this machine doesn't trust the lab root yet: make trust-root"
fi
if getent hosts "${ARGOCD_HOST}" | grep -q "^${GATEWAY_IP} "; then
  ok "${ARGOCD_HOST} resolves to ${GATEWAY_IP} (AdGuard rewrite)"
else
  bad "${ARGOCD_HOST} does not resolve to ${GATEWAY_IP}: check the AdGuard *.lab.macpro rewrite"
fi

echo "6. Storage"
check "default StorageClass is local-path" sh -c "kubectl get sc local-path -o jsonpath='{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}' | grep -qx true"
PV_NS="verify-storage-$$"
kubectl create namespace "${PV_NS}" >/dev/null 2>&1
kubectl -n "${PV_NS}" apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: probe}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: probe}
spec:
  securityContext: {runAsNonRoot: true, runAsUser: 65534, fsGroup: 65534, seccompProfile: {type: RuntimeDefault}}
  restartPolicy: Never
  containers:
    - name: probe
      image: busybox:1.37.0
      command: [sh, -c, "echo ok > /data/probe && cat /data/probe"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: probe}}]
YAML
check "PVC binds and a pod writes to it" kubectl -n "${PV_NS}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe --timeout=120s
pv_path="$(kubectl get pv "$(kubectl -n "${PV_NS}" get pvc probe -o jsonpath='{.spec.volumeName}' 2>/dev/null)" -o jsonpath='{.spec.hostPath.path}{.spec.local.path}' 2>/dev/null)"
[[ "${pv_path}" == /var/mnt/local-path-provisioner/* ]] && ok "PV on the worker data disk (${pv_path%%_*}…)" || bad "PV path '${pv_path}' (want /var/mnt/local-path-provisioner/…)"
kubectl delete namespace "${PV_NS}" --wait=false >/dev/null 2>&1

echo "7. Secrets"
# the chart uses updateStrategy OnDelete, which `rollout status` rejects: check the pod instead
check "OpenBao ready" kubectl -n openbao wait --for=condition=Ready pod/openbao-0 --timeout=120s
bao_status="$(kubectl -n openbao exec openbao-0 -- bao status -format=json 2>/dev/null)"
python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not (d["initialized"] and not d["sealed"] and d["type"]=="static"))' <<<"${bao_status}" 2>/dev/null \
  && ok "OpenBao initialized + unsealed (static seal)" || bad "OpenBao status: ${bao_status//$'\n'/ }"
store_ready() { kubectl get clustersecretstore openbao -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True; }
check "ClusterSecretStore openbao Ready" retry 18 10 store_ready
es_synced() {
  kubectl get externalsecrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | awk 'NF {n++; if ($2!="True") bad++} END {exit !(n > 0 && bad == 0)}'
}
if retry 18 10 es_synced; then
  ok "all ExternalSecrets synced ($(kubectl get externalsecrets -A --no-headers | wc -l))"
else
  bad "ExternalSecrets not all synced:"; kubectl get externalsecrets -A 2>&1 | sed 's/^/       /'
fi
check "OpenBao UI https://bao.lab.macpro" \
  retry 6 10 curl -fsS -m 5 -o /dev/null --cacert "${ROOT_CA}" --resolve "bao.lab.macpro:443:${GATEWAY_IP}" https://bao.lab.macpro/ui/

echo "8. Terraform state (Garage on the Mac Pro host)"
S3="s3.lab.macpro" S3_IP="${LAB_HOST:-192.168.8.207}"
garage_up() {
  ssh -o BatchMode=yes macpro "docker inspect -f '{{.State.Running}}' homelab-garage-garage-1 homelab-garage-caddy-1" \
    | grep -c true | grep -qx 2
}
check "Garage + TLS proxy containers running on the host" garage_up
check "${S3} resolves to ${S3_IP} (AdGuard rewrite)" sh -c "getent ahostsv4 ${S3} | awk 'NR==1{print \$1}' | grep -qx ${S3_IP}"
check "S3 TLS certificate valid for more than 30 days (make garage renews)" \
  sh -c "! step certificate needs-renewal '${ROOT}/.cache/garage/tls/s3.crt' --expires-in 720h"
state_objects() {
  local id secret
  id="$(awk '/aws_access_key_id/{print $3}' "${ROOT}/.cache/garage/credentials")"
  secret="$(awk '/aws_secret_access_key/{print $3}' "${ROOT}/.cache/garage/credentials")"
  curl -fsS -m 10 --cacert "${ROOT_CA}" --resolve "${S3}:3900:${S3_IP}" --aws-sigv4 "aws:amz:garage:s3" \
    --user "${id}:${secret}" -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "https://${S3}:3900/tfstate?list-type=2" \
    | grep -o '<Key>[^<]*</Key>' | grep -c -e host/terraform.tfstate -e talos/terraform.tfstate | grep -qx 2
}
check "tfstate bucket holds host + talos state (TLS verified against the lab root)" state_objects

echo
printf '%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
