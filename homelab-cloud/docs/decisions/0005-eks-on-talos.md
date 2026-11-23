# 0005: "EKS": Talos Linux + Cilium, bootstrapped once, then owned by Argo CD

- Status: accepted
- Date: 2026-11-19

## Decision

| Piece | Choice | Why |
|---|---|---|
| OS / Kubernetes | Talos v1.14.6, Kubernetes 1.37.2, 1 control plane + 2 workers | Immutable, API-driven OS: the closest local equivalent of a managed node group. No SSH, no drift |
| Image | Image Factory `metal` qcow2, schematic `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515` (qemu-guest-agent) | Content-addressed schematic pins the extension set; image hash pinned in `scripts/fetch-images.sh` |
| Node addressing | OPNsense DHCP reservations (MAC → `10.10.1.20–22`), names `talos-*.lab.macpro` | Nodes boot into maintenance mode at a known IP, so `terraform/talos` can apply config with no manual step |
| DNS / time | OPNsense (`10.10.1.1`) via `ResolverConfig` / `TimeSyncConfig` | Like the Route 53 Resolver and AWS Time Sync: one in-VPC source |
| CNI / LB / ingress | Cilium 1.20.5: kube-proxy replacement, LB IPAM + L2 announcements (`10.10.1.200–220`), Gateway API (CRDs v1.6.3) | One component instead of CNI + MetalLB + an ingress controller, which matters at 1 GiB per node |
| GitOps | Argo CD 3.6.2 (chart 10.18.2), app-of-apps in `k8s/bootstrap/apps` | Argo manages itself, Cilium, the CRDs and the Gateway |

## The bootstrap problem

Nodes stay `NotReady` without a CNI, and Argo CD can't run without one, so Argo can't install Cilium.
`scripts/bootstrap-cluster.sh` breaks the loop **once**: CRDs → `helm install` Cilium → wait for nodes Ready →
`helm install` Argo CD → repo credential → bootstrap secrets (SOPS) → root app → wait until every Application
is Synced/Healthy. It reads the chart versions from the Application
manifests, so Argo then adopts the same releases with the same values. After that, changes go through Git only.

## Talos 1.14 specifics (learned the hard way)

- Machine config is **multi-document**. `machine.install`, `machine.network.nameservers`, hostname and
  `machine.kubelet` are rejected as conflicts with the generated `UnattendedInstallConfig`, `ResolverConfig`,
  `HostnameConfig` and `KubeletConfig` documents; patches must target those kinds.
- No CNI / no kube-proxy is now `KubeFlannelCNIConfig: $patch: delete` + `KubeProxyConfig: enabled: false`,
  and both are **control-plane-only** documents (rejected on workers).
- The generated `HostnameConfig` uses `auto: stable`, which conflicts with a static `hostname`; the patch deletes
  the document and adds a new one.
- `talos_cluster_health` can't run inside Terraform here: even with `skip_kubernetes_checks`, Talos only
  reports "boot finished" when every node is `Ready`, which needs the CNI.
- The health gate enforces the documented minimum memory: control plane ≥ 1698 MiB (ADR 0002).

## Consequences

- Credentials (`kubeconfig`, `talosconfig`, Argo CD deploy key) live in the git-ignored `.cache/cluster/`.
- Single control plane: `https://10.10.1.20:6443` is the API endpoint. HA (3 CPs + VIP) is a later option.
