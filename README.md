# homelab-cloud

A production-shaped **AWS-like platform** built entirely as code on one Mac Pro (Late 2013):
VPC → "EKS" → managed-service equivalents → GitOps CI/CD → DevSecOps tooling, plus AWS-provider Terraform
modules tested against the AWS Emulator.

> Status: **Phase 3 in progress** (managed-service equivalents). Done: Phase 1 VPC + OPNsense
> ([ADR 0003](docs/decisions/0003-vpc-networking.md)), Phase 2 "EKS": Talos v1.14.6 + Cilium 1.20.5 + Argo CD 3.6.2
> ([ADR 0005](docs/decisions/0005-eks-on-talos.md)). Phase 3 so far: persistent volumes via local-path-provisioner
> on dedicated worker disks ([ADR 0006](docs/decisions/0006-storage-and-state.md)); TLS everywhere from a private,
> name-constrained CA: step-ca + cert-manager ([ADR 0007](docs/decisions/0007-private-pki.md)); secrets from OpenBao via
> External Secrets, self-initialized and seeded on every rebuild ([ADR 0008](docs/decisions/0008-secrets-openbao.md)).
> Argo CD UI: https://argocd.lab.macpro/ ([access runbook](docs/runbooks/cluster-access.md)).

## Architecture

Solid = built, dashed boxes = later phases.

```mermaid
flowchart LR
  subgraph LAN["Home LAN 192.168.8.0/24"]
    ws[Workstation<br/>terraform · talosctl · kubectl]
    dns[AdGuard Home<br/>192.168.8.1]
  end
  subgraph host["Mac Pro: KVM/libvirt (the 'region')"]
    opn[OPNsense VM 192.168.8.115<br/>router · NAT · firewall<br/>Unbound DNS · NTP · DHCP]
    subgraph pub["public subnet 10.10.0.0/24"]
      pubnote[reserved]
    end
    subgraph priv["private subnet 10.10.1.0/24"]
      gw[Cilium Gateway 10.10.1.200<br/>HTTPS *.lab.macpro]
      pki[step-ca + cert-manager<br/>wildcard cert]
      bao[OpenBao + External Secrets]
      cp[talos-cp-1 .20]
      w1[talos-worker-1 .21]
      w2[talos-worker-2 .22]
      argo[Argo CD<br/>app-of-apps]
    end
    subgraph data["data subnet 10.10.2.0/24"]
      db[(CNPG · Garage)]
    end
  end
  gh[(GitHub repo)]
  ws -- "qemu+ssh (Terraform)" --> host
  ws -- "route 10.10.0.0/16<br/>kube API · Talos API · HTTP" --> opn
  LAN <--> opn
  opn --- pub & priv & data
  opn -. "DNS forward" .-> dns
  gw --> argo
  pki -. "TLS cert" .-> gw
  bao -. "secrets" .-> pki
  cp & w1 & w2 --- gw
  argo -- "deploy key (read-only)" --> gh
  dns -. "rewrite *.lab.macpro" .-> gw
  style pubnote stroke-dasharray: 5 5
  style db stroke-dasharray: 5 5
```

| AWS | Here |
|---|---|
| EC2 / VPC | KVM + libvirt, OPNsense |
| EKS | Talos Linux + Cilium |
| S3 / RDS / ECR | Garage / CloudNativePG / Harbor |
| IAM / Secrets Manager | Keycloak / OpenBao + External Secrets |
| CodePipeline / CodeDeploy | Forgejo Actions / Argo CD + Rollouts |
| CloudWatch | kube-prometheus-stack + Loki |
| Security (CNAPP, EDR, SCPs) | Trivy Operator, Kubescape, Falco, Wazuh, Kyverno, DefectDojo |

## Usage

```sh
make help     # list targets
make hooks    # install pinned tools + git hooks
make lint     # pre-commit on all files
make temps    # host CPU temperatures
make up       # build the lab: VPC + OPNsense, Talos cluster, Cilium, Argo CD (~15 min)
make route    # sudo: route 10.10.0.0/16 via OPNsense on this workstation
make verify   # cluster acceptance checks (verify-host: Phase 1, needs the test VM)
make destroy  # tear it down
```

Manual one-time steps: [docs/bootstrap.md](docs/bootstrap.md). Design decisions: [docs/decisions/](docs/decisions/).

## Layout

```
terraform/host   libvirt networks, pools, VMs        k8s/bootstrap  Argo CD + root app
terraform/talos  Talos machine configs / bootstrap   k8s/platform   managed-service equivalents
terraform/aws    real-AWS-shaped modules             k8s/security   policy, runtime, posture
apps/            sample service(s)                   .forgejo/      CI pipelines
```
