#!/usr/bin/env bash
# Phase 2 acceptance checks, run from the admin workstation after `make up` (which also sets the lab route):
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
#      more than 30 days left, both stacks' state objects are in the tfstate bucket, and the Garage UI
#      answers behind its login.
#   9. Databases: CNPG operator + Barman Cloud plugin up, pg-demo healthy with 2 instances, WAL archiving to
#      Garage works and a base backup completed. The full restore test is make db-restore-test.
#  10. Identity: Keycloak operator + instance Ready, keycloak-db healthy and archiving, the lab realm's OIDC
#      discovery served on https://sso.lab.macpro (lab CA), and a real Argo CD SSO login as labadmin.
#  11. Registry (Harbor): every component Ready, harbor-db healthy and archiving, the health API all green,
#      login via Keycloak (OIDC), a test image pushed (crane), scanned by Trivy, and pulled by a pod from
#      registry.lab.macpro (the nodes trust the lab CA for it).
#  12. Observability: kubectl top (metrics-server, kubelet certificates verified), the monitoring stack ready,
#      every Prometheus target up (incl. etcd, controller manager, scheduler, Argo CD), a real Grafana SSO login,
#      logs and Kubernetes events in Loki, Loki's objects in Garage, and a test alert reaching ntfy.
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
# The VPC resolves lab.macpro like the LAN (ADR 0004): Gateway names and Garage, plus the nodes' own names
LAB_DNS_OVERRIDES='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"dns","image":"busybox:1.37.0","command":["sh","-c","for n in argocd.lab.macpro s3.lab.macpro talos-cp-1.lab.macpro; do echo \"$n=$(nslookup $n 2>/dev/null | awk \"/^Address: /{print \\$2}\" | head -1)\"; done"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
lab_dns() {
  lab_out="$(kubectl run "verify-labdns-$$" --rm -i --restart=Never --quiet --image=busybox:1.37.0 \
    --overrides="${LAB_DNS_OVERRIDES}" 2>&1)"
  grep -qx "argocd.lab.macpro=${GATEWAY_IP}" <<<"${lab_out}" \
    && grep -qx "s3.lab.macpro=${LAB_HOST:-192.168.8.207}" <<<"${lab_out}" \
    && grep -qx "talos-cp-1.lab.macpro=10.10.1.20" <<<"${lab_out}"
}
if retry 4 15 lab_dns; then
  ok "pod resolves lab.macpro like the LAN (Gateway, Garage, node names)"
else
  bad "pod lab.macpro DNS: ${lab_out//$'\n'/ }"
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
ui_wall() { [[ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' --cacert "${ROOT_CA}" --resolve "${S3}:3909:${S3_IP}" "https://${S3}:3909/api/v1/buckets")" == 401 ]]; }
check "Garage UI https://${S3}:3909 up behind its login (API without login: 401)" ui_wall

echo "9. Databases (CloudNativePG, backups to Garage)"
check "CNPG operator + Barman Cloud plugin ready" sh -c \
  "kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=120s && kubectl -n cnpg-system rollout status deploy/cnpg-barman-plugin-plugin-barman-cloud --timeout=120s"
cluster_healthy() { kubectl -n databases get cluster pg-demo -o jsonpath='{.status.phase} {.status.readyInstances}' | grep -qx 'Cluster in healthy state 2'; }
check "pg-demo healthy, 2 instances (primary + streaming replica)" retry 30 10 cluster_healthy
archiving() { kubectl -n databases get cluster pg-demo -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}' | grep -qx True; }
check "pg-demo WAL archiving to Garage works (ContinuousArchiving)" retry 30 10 archiving
base_backup() { kubectl -n databases get backups -o jsonpath='{range .items[*]}{.spec.cluster.name} {.status.phase}{"\n"}{end}' | grep -qx 'pg-demo completed'; }
check "pg-demo has a completed base backup in Garage" retry 30 10 base_backup

echo "10. Identity (Keycloak, SSO for Argo CD)"
check "Keycloak operator ready" kubectl -n keycloak rollout status deploy/keycloak-operator --timeout=120s
kc_ready() { kubectl -n keycloak get keycloak keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -qx True; }
check "Keycloak instance Ready" retry 30 10 kc_ready
kcdb_ok() {
  retry 30 10 sh -c "kubectl -n databases get cluster keycloak-db -o jsonpath='{.status.phase} {.status.readyInstances}' | grep -qx 'Cluster in healthy state 2'" &&
    retry 30 10 sh -c "kubectl -n databases get cluster keycloak-db -o jsonpath='{.status.conditions[?(@.type==\"ContinuousArchiving\")].status}' | grep -qx True"
}
check "keycloak-db healthy, 2 instances, WAL archiving to Garage" kcdb_ok
discovery() {
  curl -fsS -m 10 --cacert "${ROOT_CA}" https://sso.lab.macpro/realms/lab/.well-known/openid-configuration \
    | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["issuer"] != "https://sso.lab.macpro/realms/lab")'
}
check "realm lab: OIDC discovery on https://sso.lab.macpro, issuer correct, TLS from the lab CA" retry 12 10 discovery
sso_login() {
  SSO_USER=labadmin SSO_PASSWORD="$(SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt" sops --decrypt \
    --extract '["data"]["keycloak-labadmin-password"]' "${ROOT}/k8s/platform/openbao/seed.enc.yaml" | base64 -d)" \
    "${ROOT}/scripts/sso-login-test.py" "${ROOT_CA}"
}
if out="$(retry 6 10 sso_login 2>&1)"; then ok "Argo CD SSO: ${out##*$'\n'}"; else bad "Argo CD SSO login as labadmin: ${out##*$'\n'}"; fi

echo "11. Registry (Harbor)"
REG="registry.lab.macpro"
TEST_REPO="library/verify-busybox"
harbor_up() {
  for d in harbor-core harbor-jobservice harbor-portal harbor-registry; do
    kubectl -n harbor rollout status "deploy/${d}" --timeout=10s || return 1
  done
  for s in harbor-redis harbor-trivy; do kubectl -n harbor rollout status "sts/${s}" --timeout=10s || return 1; done
}
check "Harbor components ready (core, jobservice, portal, registry, redis, trivy)" retry 30 10 harbor_up
hdb_ok() {
  retry 30 10 sh -c "kubectl -n databases get cluster harbor-db -o jsonpath='{.status.phase} {.status.readyInstances}' | grep -qx 'Cluster in healthy state 2'" &&
    retry 30 10 sh -c "kubectl -n databases get cluster harbor-db -o jsonpath='{.status.conditions[?(@.type==\"ContinuousArchiving\")].status}' | grep -qx True"
}
check "harbor-db healthy, 2 instances, WAL archiving to Garage" hdb_ok
harbor_health() {
  curl -fsS -m 10 --cacert "${ROOT_CA}" "https://${REG}/api/v2.0/health" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(d["status"] != "healthy")'
}
check "https://${REG}/api/v2.0/health: every component healthy (TLS from the lab CA)" retry 18 10 harbor_health
oidc_mode() {
  curl -fsS -m 10 --cacert "${ROOT_CA}" "https://${REG}/api/v2.0/systeminfo" \
    | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin).get("auth_mode") != "oidc_auth")' &&
  curl -s -m 10 -o /dev/null -w '%{redirect_url}' --cacert "${ROOT_CA}" "https://${REG}/c/oidc/login" \
    | grep -q '^https://sso.lab.macpro/realms/lab/'
}
check "login via Keycloak: auth mode oidc_auth, /c/oidc/login redirects to the lab realm" retry 6 10 oidc_mode

# push / scan / pull: crane gets a throwaway docker config and a CA bundle with the lab root added
work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
cat /etc/ssl/certs/ca-certificates.crt "${ROOT_CA}" > "${work}/ca.crt" 2>/dev/null || cp "${ROOT_CA}" "${work}/ca.crt"
HARBOR_ADMIN="$(SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt" sops --decrypt \
  --extract '["data"]["harbor-admin-password"]' "${ROOT}/k8s/platform/openbao/seed.enc.yaml" | base64 -d)"
hapi() { curl -fsS -m 20 --cacert "${ROOT_CA}" -u "admin:${HARBOR_ADMIN}" "$@"; }
push_image() {
  DOCKER_CONFIG="${work}" SSL_CERT_FILE="${work}/ca.crt" crane auth login "${REG}" -u admin -p "${HARBOR_ADMIN}" >/dev/null 2>&1 &&
    DOCKER_CONFIG="${work}" SSL_CERT_FILE="${work}/ca.crt" crane copy docker.io/library/busybox:1.37.0 \
      "${REG}/${TEST_REPO}:1.37.0" --platform linux/amd64 >/dev/null 2>&1
}
check "push: busybox:1.37.0 -> ${REG}/${TEST_REPO}:1.37.0 (crane, as admin)" retry 3 10 push_image
# Read first, queue a scan only when there's none yet (or it failed): re-queuing on every try reset the status
# to Running each time, so the check never saw Success (2026-11-23)
scanned() {
  local a="https://${REG}/api/v2.0/projects/library/repositories/verify-busybox/artifacts/1.37.0" st
  st="$(hapi "${a}?with_scan_overview=true" | python3 -c '
import json,sys; o=(json.load(sys.stdin).get("scan_overview") or {})
print(next((v.get("scan_status") for v in o.values()), "none"))')"
  [[ "${st}" == Success ]] && return 0
  [[ "${st}" == none || "${st}" == Error || "${st}" == Stopped ]] && hapi -X POST "${a}/scan" -o /dev/null 2>/dev/null
  return 1
}
# up to 10 min: before its first scan Trivy downloads its vulnerability DB (that alone took >5 min on 2026-11-23)
check "Trivy scanned it (scan status Success)" retry 60 10 scanned
PULL_OVERRIDES='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"pull","image":"'"${REG}/${TEST_REPO}"':1.37.0","command":["echo","pulled-from-harbor"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
# no `kubectl run -i`: echo exits before the attach, so its output (and the --rm) would be lost; run the pod,
# wait for it to succeed, then read its log
pod_pull() {
  local p="verify-pull-$$" ok=1
  kubectl run "${p}" --restart=Never --image="${REG}/${TEST_REPO}:1.37.0" --image-pull-policy=Always \
    --overrides="${PULL_OVERRIDES}" >/dev/null 2>&1 &&
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${p}" --timeout=120s >/dev/null 2>&1 &&
    kubectl logs "${p}" 2>/dev/null | grep -q pulled-from-harbor && ok=0
  kubectl delete pod "${p}" --wait=false >/dev/null 2>&1
  return "${ok}"
}
check "a pod pulls ${REG}/${TEST_REPO}:1.37.0 (containerd trusts the lab CA for the registry)" retry 3 10 pod_pull
unset HARBOR_ADMIN

echo "12. Observability (metrics, logs, alerts)"
# kubectl top only works if metrics-server can verify every kubelet's serving certificate: CA-signed through
# Talos serverTLSBootstrap + kubelet-serving-cert-approver (ADR 0014)
top_nodes() { [[ "$(kubectl top nodes --no-headers 2>/dev/null | wc -l)" -eq 3 ]]; }
check "metrics-server: kubectl top shows all 3 nodes (kubelet certificates verified)" retry 18 10 top_nodes
mon_up() {
  kubectl -n monitoring rollout status deploy/kps-grafana --timeout=10s &&
    kubectl -n monitoring rollout status deploy/kps-kube-prometheus-stack-operator --timeout=10s &&
    kubectl -n monitoring rollout status deploy/kps-kube-state-metrics --timeout=10s &&
    kubectl -n monitoring rollout status ds/kps-prometheus-node-exporter --timeout=10s &&
    kubectl -n monitoring rollout status sts/prometheus-kps-kube-prometheus-stack-prometheus --timeout=10s &&
    kubectl -n monitoring rollout status sts/alertmanager-kps-kube-prometheus-stack-alertmanager --timeout=10s &&
    kubectl -n monitoring rollout status sts/loki --timeout=10s &&
    kubectl -n monitoring rollout status deploy/alloy --timeout=10s &&
    kubectl -n monitoring rollout status deploy/ntfy --timeout=10s
}
check "Prometheus, Alertmanager, Grafana, Loki, Alloy, ntfy and the exporters ready" retry 30 10 mon_up
PROM="/api/v1/namespaces/monitoring/services/http:kps-kube-prometheus-stack-prometheus:9090/proxy"
# every scrape target up, and the ones that need the Talos changes or our ServiceMonitors are there at all
targets_up() {
  kubectl get --raw "${PROM}/api/v1/targets?state=active" | python3 -c '
import json, sys
t = json.load(sys.stdin)["data"]["activeTargets"]
jobs = {x["labels"].get("job") for x in t}
down = sorted({x["labels"].get("job", "?") + " " + x["labels"].get("instance", "") for x in t if x["health"] != "up"})
need = {"kubelet", "apiserver", "kube-etcd", "kube-controller-manager", "kube-scheduler", "node-exporter",
        "kube-state-metrics", "loki", "alloy", "ntfy"}
missing = {n for n in need if not any(j and (j == n or j.endswith("/" + n)) for j in jobs)}   # loki: "monitoring/loki"
argocd = [j for j in jobs if j and j.startswith("argocd")]
if down or missing or len(argocd) < 3:
    print("down:", down, "missing:", sorted(missing), "argocd jobs:", sorted(argocd)); sys.exit(1)
print(f"{len(t)} targets up, incl. etcd, controller manager, scheduler, kubelets (TLS verified) and Argo CD")'
}
if out="$(retry 18 10 targets_up 2>&1)"; then ok "Prometheus: ${out##*$'\n'}"; else bad "Prometheus targets: ${out##*$'\n'}"; fi
grafana_sso() {
  SSO_USER=labadmin SSO_PASSWORD="$(SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt" sops --decrypt \
    --extract '["data"]["keycloak-labadmin-password"]' "${ROOT}/k8s/platform/openbao/seed.enc.yaml" | base64 -d)" \
    "${ROOT}/scripts/grafana-sso-test.py" "${ROOT_CA}"
}
if out="$(retry 6 10 grafana_sso 2>&1)"; then ok "Grafana SSO: ${out##*$'\n'}"; else bad "Grafana SSO login as labadmin: ${out##*$'\n'}"; fi
LOKI="/api/v1/namespaces/monitoring/services/http:loki:3100/proxy"
# Alloy -> Loki: lines from this namespace in the last 10 minutes, and Kubernetes events
loki_has() {
  kubectl get --raw "${LOKI}/loki/api/v1/query?query=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; sys.exit(not r or float(r[0]["value"][1]) <= 0)'
}
check "Loki holds pod logs (Alloy ships them through the API)" retry 18 10 loki_has 'sum(count_over_time({namespace="monitoring"}[10m]))'
check "Loki holds Kubernetes events" retry 18 10 loki_has 'sum(count_over_time({job="integrations/kubernetes/eventhandler"}[30m]))'
# Loki writes to Garage: its cluster seed object exists in bucket loki (TLS + key work)
loki_s3() {
  local kid sec
  read -r kid sec < <(SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt" sops --decrypt "${ROOT}/host/garage/secrets.enc.yaml" \
    | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin)["stringData"]; print(d["loki_key_id"], d["loki_secret_key"])')
  curl -fsS -m 10 --cacert "${ROOT_CA}" --aws-sigv4 "aws:amz:garage:s3" --user "${kid}:${sec}" \
    -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' "https://s3.lab.macpro:3900/loki?list-type=2&max-keys=1000" \
    | grep -q '<Key>'
}
check "Loki stores into Garage (bucket loki has objects)" retry 18 10 loki_s3
# The alert path end to end: a test alert into Alertmanager's API, then it must show up in ntfy topic lab-alerts
# (read as labadmin, through the Gateway). Ends after 2 min, so it resolves by itself.
AM="/api/v1/namespaces/monitoring/services/http:kps-kube-prometheus-stack-alertmanager:9093/proxy"
NTFY_PW="$(SOPS_AGE_KEY_FILE="${ROOT}/.cache/age/key.txt" sops --decrypt \
  --extract '["data"]["monitoring-ntfy-labadmin-password"]' "${ROOT}/k8s/platform/openbao/seed.enc.yaml" | base64 -d)"
ALERT_ID="VerifyTestAlert$$"
since="$(date +%s)"
send_alert() {
  python3 -c 'import json,sys,datetime as d
n=d.datetime.now(d.timezone.utc); f=lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps([{"labels": {"alertname": sys.argv[1], "severity": "info", "namespace": "verify"},
  "annotations": {"summary": "make verify: test alert, resolves by itself"},
  "startsAt": f(n), "endsAt": f(n + d.timedelta(minutes=2))}]))' "${ALERT_ID}" \
    | kubectl create --raw "${AM}/api/v2/alerts" -f - >/dev/null
}
in_ntfy() {
  curl -fsS -m 10 --cacert "${ROOT_CA}" -u "labadmin:${NTFY_PW}" "https://ntfy.lab.macpro/lab-alerts/json?poll=1&since=${since}" \
    | grep -q "${ALERT_ID}"
}
if retry 6 10 send_alert && retry 18 10 in_ntfy; then
  ok "alerting: a test alert went Alertmanager -> ntfy (https://ntfy.lab.macpro, topic lab-alerts)"
else
  bad "alerting: test alert ${ALERT_ID} not seen in ntfy topic lab-alerts"
fi
unset NTFY_PW

echo
printf '%d passed, %d failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
