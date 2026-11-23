# Runbook: observability (metrics, logs, alerts)

Design: [ADR 0014](../decisions/0014-observability.md). Everything is in namespace `monitoring`. The lab TUI (the
terminal monitor) is a separate thing: [monitoring.md](monitoring.md).

## Access

| What | Where | Login |
|---|---|---|
| Grafana | https://grafana.lab.macpro | **Sign in with Keycloak** as `labadmin` (group `grafana-admins` = Admin); local `admin` is break-glass (`make logins`) |
| Alerts | https://ntfy.lab.macpro, topic `lab-alerts` | `labadmin`, ntfy password from `make logins`. Phone: the ntfy app, server `https://ntfy.lab.macpro` (on the LAN, with the lab root trusted) |
| Prometheus / Alertmanager UIs | not exposed; `kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9090` (or `-alertmanager 9093`) | none (localhost only) |
| Logs | Grafana → Explore → **Loki**, e.g. `{namespace="harbor", container="core"}` or `{job="integrations/kubernetes/eventhandler"}` for events | |

## Check

```sh
make verify                                       # section 12: top, targets, Grafana SSO, Loki, alert -> ntfy
kubectl top nodes
kubectl -n monitoring get pods
kubectl get csr | grep kubelet-serving            # Approved,Issued for every node after a boot
```

## Common jobs

| Job | How |
|---|---|
| Add a dashboard | A ConfigMap labelled `grafana_dashboard: "1"` in any namespace (Grafana's sidecar loads it); see `k8s/platform/monitoring/extras` |
| Scrape an app | A `ServiceMonitor` or `PodMonitor` in the app's namespace (every one in the cluster is picked up) |
| Add an alert | A `PrometheusRule` in the app's namespace; Alertmanager sends every alert except Watchdog to ntfy |
| Silence an alert | port-forward Alertmanager, then its UI → Silences |
| Test the alert path | `make verify` sends a test alert that resolves itself after 2 min |
| Make someone a Grafana admin | Add them to `grafana-admins` in `terraform/identity`, `make identity` |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `kubectl logs`/`exec` fail with a TLS error, or `kubectl top` says metrics not available | Kubelet serving CSRs not approved yet: `kubectl get csr`; is `kubelet-serving-cert-approver` running? `kubectl -n kubelet-serving-cert-approver logs deploy/kubelet-serving-cert-approver` |
| Targets kube-etcd / kube-scheduler / kube-controller-manager down | They're static ScrapeConfigs (`k8s/platform/monitoring/extras/scrapeconfigs.yaml`) on the node's ports, which the Talos patch opens: check it's applied (`talosctl -n 10.10.1.20 get mc -o yaml \| grep -e bind-address -e listen-metrics`), else `scripts/tf.sh talos apply`. **etcd** only picks up a changed argument at the control plane's next boot (Talos can't restart etcd on its own): `talosctl -n 10.10.1.20 netstat -l \| grep 2381` |
| Grafana login loops or `invalid_client` | Client secret differs between Keycloak and Grafana: OpenBao `secret/monitoring/grafana-oidc` vs the seed, then `make identity` |
| Grafana: "x509: certificate signed by unknown authority" on login | The `lab-root-ca` Secret (from `scripts/pki-render.py`) isn't mounted: check `kubectl -n monitoring get secret lab-root-ca` |
| No logs in Loki | `kubectl -n monitoring logs deploy/alloy`; then Loki: `kubectl -n monitoring logs sts/loki` (S3 errors point to Garage: `make verify` section 8) |
| Events missing in Loki, or still under `job="loki.source.kubernetes_events"` after a config change | Alloy's live reload doesn't apply every change to `loki.source.kubernetes_events` (seen with `job_name`): `kubectl -n monitoring rollout restart deploy/alloy`. Older lines keep their old labels |
| No notifications | ntfy's log (`kubectl -n monitoring logs deploy/ntfy`): a 401/403 means the token doesn't match OpenBao `secret/monitoring/ntfy`; Alertmanager's log shows the webhook result |
