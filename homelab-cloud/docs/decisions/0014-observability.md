# 0014: Observability ("CloudWatch"): kube-prometheus-stack, Loki on Garage, Alloy, alerts to ntfy, Grafana SSO

- Status: accepted
- Date: 2026-11-23
- Phase 4, milestone 1. Builds on: [ADR 0010](0010-garage-host-s3.md) (Garage), [ADR 0012](0012-identity-keycloak.md)
  (Keycloak)

## Decision

| Piece | Choice | Why |
|---|---|---|
| Metrics + alerting | **kube-prometheus-stack 93.1.1** (Prometheus Operator v0.95.1, Grafana 13.3.0), namespace `monitoring` | The standard bundle: Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics, and the upstream rules and dashboards. The chart releases almost daily; 93.1.1 is the newest past the two-week rule |
| Prometheus storage | local-path PVC 10 GiB, **7 days**, capped at 8 GB | Metrics are rebuilt with the lab; a week covers any debugging session |
| Logs | **Loki 3.7.10**, single binary, one replica, **grafana-community chart 21.2.3**; chunks and index in Garage bucket **`loki`** (own key), 7 days | Same shape as the other data stores (S3 on Garage, wiped by `make destroy`). 3.7.10 carries golang.org/x/net and x/crypto security fixes, so it's taken at 10 days old. Grafana's charts moved to the grafana-community repo; the old `grafana/loki` chart is still on Loki 3.6 |
| Log shipping | **Grafana Alloy v1.22.0** (chart 1.16.0), **one Deployment**, reading logs through the Kubernetes API (`loki.source.kubernetes`) plus Kubernetes events | No hostPath mounts on the Talos nodes and no DaemonSet. Fine at this volume (it streams every container's log through the API server). v1.22.0 fixes a HIGH in its UI's vite, so it's taken at 10 days old |
| Alert delivery | **ntfy v2.38.1** at https://ntfy.lab.macpro, topic `lab-alerts`; Alertmanager posts with a token through ntfy's built-in `alertmanager` template | Like SNS behind CloudWatch alarms: a phone app or browser tab on the LAN. 2.38.1 is a security release (template DoS hardening) |
| ntfy access | `deny-all` by default; users, ACL and token **declarative** (env from an ExternalSecret): `alertmanager` write-only by token, `labadmin` read-only by password | Nothing anonymous; no `ntfy user` commands after a rebuild. bcrypt hashes come from the seed (`htpasswd -C 10`, ntfy's minimum cost) |
| Grafana login | **Keycloak OIDC** (client `grafana`, PKCE), group **`grafana-admins`** → Admin, others Viewer; the local `admin` stays as break-glass; no persistence | Same IdP as Argo CD and Harbor. Users are recreated at login, dashboards and datasources are provisioned, so the SQLite file holds nothing worth keeping |
| `kubectl top` | **metrics-server 0.9.0** (chart 3.14.0), verifying kubelet TLS | The resource metrics API (HPA, `kubectl top`, the TUI) |
| Kubelet certificates | Talos `KubeletConfig` **`serverTLSBootstrap: true`** + **kubelet-serving-cert-approver v0.12.1** | Kubelets get serving certificates signed by the cluster CA instead of self-signed ones, so metrics-server and Prometheus verify them. No `--kubelet-insecure-tls`, no `insecureSkipVerify` on the kubelet scrape. The approver checks each CSR's names and IPs against the node |
| Control-plane metrics | Talos: controller manager and scheduler `bind-address: 0.0.0.0`, etcd `listen-metrics-urls: http://0.0.0.0:2381`; scraped by static **ScrapeConfigs** on `10.10.1.20` (`k8s/platform/monitoring/extras/scrapeconfigs.yaml`), the chart's Services for them off | Talos binds them to localhost by default. The controller manager and scheduler still require an authorized token; their serving certificates are self-signed by the components, so those two scrapes skip TLS verification. etcd's metrics port serves `/metrics` and `/health` only. Not the chart's Services: they need hand-written `Endpoints`, which Argo CD doesn't sync (see below) |
| Argo CD metrics | `metrics.enabled` in Argo CD's chart (Services only); the ServiceMonitors and Argo CD's upstream dashboard (v3.6.2) live in `k8s/platform/monitoring/extras` | The bootstrap installs Argo CD's chart before the ServiceMonitor CRD exists |
| Operator webhook | `admissionWebhooks.certManager.enabled` (cert-manager issues its certificate), `caBundle` ignored in Argo CD's diff | Instead of the chart's create/patch hook Jobs |

## Secrets (seed → OpenBao `secret/monitoring/*` → External Secrets)

`monitoring-grafana-admin-password`, `keycloak-grafana-client-secret` (also passed to `terraform/identity`),
`monitoring-loki-s3-*` (from `host/garage/secrets.enc.yaml`, bucket `loki`), `monitoring-ntfy-alertmanager-token`
(`tk_` + 29 characters, ntfy's format), `monitoring-ntfy-labadmin-password` + `-hash`,
`monitoring-ntfy-alertmanager-hash` (its password is random and discarded: it only uses the token). Namespace
`monitoring` is on the ClusterSecretStore's allow-list.

## Lifecycle

Like the databases and Harbor: fresh per rebuild. `make destroy` wipes Loki's prefixes in the `loki` bucket
(`fake/`, the single tenant's chunks, and `index/`); Prometheus and Alertmanager live on local-path volumes that go
with the VMs.

## Tested before deploying

- ntfy v2.38.1 in Docker with the exact declarative settings: anonymous publish and read 403, a bad token 401,
  the Alertmanager token publishes (200) but can't read (403), labadmin reads but can't publish, a wrong password
  401; an Alertmanager webhook body through `?template=alertmanager` renders as "🚨 Alert: <name>" with severity
  and summary.
- The Alloy pipeline parses with the v1.22.0 binary (`alloy fmt`).
- The Talos patches validate for Talos 1.14 (`talosctl validate`), and a dry run on the live nodes reports
  "Applied configuration without a reboot".
- All four charts render with the lab values (`helm template`): the Grafana HTTPRoute on the lab Gateway, the
  kubelet scrape verifying against `kube-root-ca.crt`, the operator's Certificates instead of hook Jobs.

## Found on first deploy

- **metrics-server not Ready (probe 500) right after the push**: the kubelets still had self-signed certificates
  (`doesn't contain any IP SANs`), because the Talos change was held back until the approver ran. After
  `scripts/tf.sh talos apply` all three kubelets got approved CA-signed certificates within seconds, no reboot.
- **etcd, controller-manager and scheduler targets missing**: the chart scrapes them through selector-less
  Services with hand-written `Endpoints`, and Argo CD excludes `Endpoints`/`EndpointSlice` from syncing by
  default (`resource.exclusions` in argocd-cm), so there was nothing to scrape. Replaced by static ScrapeConfigs
  with the same job names (the chart's rules and dashboards still match). Checked from a pod: both HTTPS ports
  answer 200 with Prometheus' token and 403 without it.
- **etcd's metrics listener needs an etcd restart**, and Talos won't restart etcd through its API ("doesn't
  support restart operation"). A machine-config change to etcd's arguments takes effect at the control plane's
  next boot. Fresh builds have it from the start; the live lab got it at its next reboot.
- **Events missing in Loki**: they arrived, under Alloy's default `job="loki.source.kubernetes_events"`; the
  config now sets the conventional `job_name = "integrations/kubernetes/eventhandler"`.
- **Verify's test alert never left**: `kubectl create --raw` through the API-server proxy is refused by
  Alertmanager (415, content type). Verify now uses `amtool` in the Alertmanager pod; the path itself worked
  (Alertmanager → ntfy in about 40 s, its `group_wait` is 30 s).

## Verification

`make verify` section 12:
- `kubectl top` shows all 3 nodes, which only works with the kubelet certificates verified
- every component is ready
- every Prometheus target is up, including etcd, the controller manager, the scheduler, the kubelets, Argo CD,
  Loki, Alloy and ntfy
- a real Grafana SSO login as labadmin gets the Admin role
- Loki holds pod logs and Kubernetes events, and has objects in Garage
- a test alert posted to Alertmanager arrives in ntfy's `lab-alerts`, read as labadmin through the Gateway

## Consequences

- Memory requests: about 1.8 GiB in all. Prometheus 768 MiB (2 GiB limit), Loki 256 MiB, Grafana 192 MiB,
  Alloy 128 MiB, the rest is small ([ADR 0002](0002-vm-sizing.md) log).
- Until the approver runs, a freshly booted node's kubelet has no serving certificate: `kubectl logs`/`exec` and
  metrics wait for it. The approver is in sync wave 0, so this window is short.
- The control-plane ScrapeConfigs name `10.10.1.20`; a second control plane adds its IP there.
- Alloy reads logs through the API server. If log volume grows a lot (Phase 5 Falco and Wazuh), switch to a
  DaemonSet reading `/var/log/pods`, which needs a hostPath and privileged Pod Security for its namespace.
