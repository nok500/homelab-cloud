# Runbook: cluster access (Argo CD, kubectl, talosctl)

All credentials live in the git-ignored `.cache/cluster/` on the admin workstation. The `make` targets export
`KUBECONFIG` / `TALOSCONFIG` for you; for an interactive shell:

```sh
cd ~/projects/lab/homelab-cloud
export KUBECONFIG=$PWD/.cache/cluster/kubeconfig TALOSCONFIG=$PWD/.cache/cluster/talosconfig
export PATH=$PWD/.tools/bin:$PATH        # pinned talosctl
```

Prerequisites on the workstation: the lab route (`make up`/`make start` add it when missing and sudo asks for your password; `make route` on its own), the lab root CA trusted
(`make trust-root`, once) and DNS for `*.lab.macpro`
(AdGuard rewrite to the Gateway, see `docs/bootstrap.md`). If nothing answers, see
[opnsense.md § Connectivity loss](opnsense.md#connectivity-loss-find-the-hop-then-recover).

## Argo CD UI

| | |
|---|---|
| URL | **https://argocd.lab.macpro/** (Cilium Gateway on `10.10.1.200`; `http://` redirects; cert from the lab CA, see [pki.md](pki.md)) |
| User | `admin` |
| Password | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d; echo` |

The initial password is random per install, so it changes after every `make destroy && make up`.
Day to day, use **LOG IN VIA KEYCLOAK**: user `labadmin`, password from `make sso-password` ([identity.md](identity.md)); every lab login at once: `make logins`. The local `admin` stays as break-glass for when Keycloak is down.

Optional hardening, per the Argo CD docs: change the password, then delete the bootstrap secret:

```sh
argocd login argocd.lab.macpro --username admin --grpc-web
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

## After `make up`

`make up` returns only once every Argo CD Application is Synced/Healthy (it prints what's still pending every
30 s; about 10–15 min after the cluster exists). Until then `https://*.lab.macpro` may fail: the wildcard
certificate is the last link in the chain (ADR 0008). argocd-server logging `redis … connection refused`
while it starts is normal: `argocd-redis` is its cache and comes up at the same time.

## Changing the Talos VMs (CPU, memory, disks)

`terraform -chdir=terraform/host apply` reports these as "updated in-place", but the libvirt provider
**power-cycles the domain** to apply them. Every changed node reboots, and its pods restart elsewhere or
wait for it. With a single control plane, changing `talos-cp-1` takes the API down for a few minutes.
Change one role at a time, then run `make verify`.

## Changing what runs in the cluster

GitOps only: edit `k8s/`, commit, push. Argo CD polls `main` (about 3 minutes), or refresh it now:

```sh
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
```

Argo CD reads the private repo with a **read-only deploy key** (`.cache/cluster/argocd-deploy-key`, public half
on the repo under Settings → Deploy keys), loaded by `scripts/bootstrap-cluster.sh` as the
`repo-homelab-cloud` secret. It stays a bootstrap secret: Argo CD needs it before OpenBao exists
(ADR 0008). Every other secret comes from OpenBao, see [secrets.md](secrets.md).

**Repo moved (2026-11-23):** the repo is now `nok500/lab` and every Argo CD path starts with `homelab-cloud/`.
A cluster built before the move still has the old root Application, so after the next `make start`, run this once
(a fresh `make up` needs nothing):

```sh
kubectl -n argocd patch secret repo-homelab-cloud --type merge \
  -p '{"stringData":{"url":"git@github.com:nok500/lab.git"}}'
kubectl apply -f k8s/bootstrap/root.yaml   # root re-syncs every child Application to the new paths
```
