# Runbook: cluster access (Argo CD, kubectl, talosctl)

All credentials live in the git-ignored `.cache/cluster/` on the admin workstation. The `make` targets export
`KUBECONFIG` / `TALOSCONFIG` for you; for an interactive shell:

```sh
cd ~/projects/lab/homelab-cloud
export KUBECONFIG=$PWD/.cache/cluster/kubeconfig TALOSCONFIG=$PWD/.cache/cluster/talosconfig
export PATH=$PWD/.tools/bin:$PATH        # pinned talosctl
```

Prerequisites on the workstation: the lab route (`make route`, once per boot) and DNS for `*.lab.macpro`
(AdGuard rewrite to the Gateway, see `docs/bootstrap.md`). If nothing answers, see
[opnsense.md § Connectivity loss](opnsense.md#connectivity-loss-find-the-hop-then-recover).

## Argo CD UI

| | |
|---|---|
| URL | http://argocd.lab.macpro/ (Cilium Gateway on `10.10.1.200`; HTTPS from Phase 3) |
| User | `admin` |
| Password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d; echo` |

The initial password is random per install, so it changes after every `make destroy && make up`.
Local admin only for now; SSO via Keycloak (OIDC) comes in Phase 3.

Optional hardening, per the Argo CD docs: change the password, then delete the bootstrap secret:

```sh
argocd login argocd.lab.macpro --plaintext --username admin --grpc-web
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

The `argocd` CLI isn't pinned in `.tools` yet; the UI and `kubectl` cover everything needed here.

### Without the Gateway (break-glass)

```sh
kubectl -n argocd port-forward svc/argocd-server 8080:80     # then http://localhost:8080
```

## kubectl

```sh
kubectl get nodes -o wide
kubectl -n argocd get applications        # all should be Synced / Healthy
```

API endpoint: `https://10.10.1.20:6443` (single control plane), reachable only from `admin_cidrs`.

## talosctl

```sh
talosctl -n 10.10.1.20 dashboard                         # live node view
talosctl -n 10.10.1.20,10.10.1.21,10.10.1.22 memory
talosctl -n 10.10.1.20 get timestatus                    # NTP via OPNsense (10.10.1.1)
talosctl -n 10.10.1.21 logs kubelet
```

Talos has no SSH; everything goes through its API on port 50000 (allowed from `admin_cidrs` only).

## Changing what runs in the cluster

GitOps only: edit `k8s/`, commit, push. Argo CD polls `main` (about 3 minutes), or refresh it now:

```sh
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```

Argo CD reads the private repo with a **read-only deploy key** (`.cache/cluster/argocd-deploy-key`, public half
on the repo under Settings → Deploy keys), loaded by `scripts/bootstrap-cluster.sh` as the
`repo-homelab-cloud` secret. It moves to OpenBao + External Secrets in Phase 3.
