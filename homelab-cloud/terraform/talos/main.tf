# the host stack's outputs (node IPs, VPC facts), read from the same Garage bucket
data "terraform_remote_state" "host" {
  backend = "s3"
  config = {
    bucket                      = "tfstate"
    key                         = "host/terraform.tfstate"
    region                      = "garage"
    endpoints                   = { s3 = "https://s3.lab.macpro:3900" }
    profile                     = "tfstate"
    shared_credentials_files    = ["../../.cache/garage/credentials"]
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

locals {
  repo_root = abspath("${path.module}/../..")
  out_dir   = "${local.repo_root}/.cache/cluster"

  net   = data.terraform_remote_state.host.outputs.network
  nodes = data.terraform_remote_state.host.outputs.talos_nodes

  controlplanes = { for name, n in local.nodes : name => n if n.role == "controlplane" }

  # Single control plane for now: its IP is the API endpoint (an EKS endpoint would be a VIP/NLB).
  cp_ip            = values(local.controlplanes)[0].ip
  cluster_endpoint = "https://${local.cp_ip}:6443"

  # Talos 1.14 machine config is multi-document: each concern has its own document kind, and setting
  # the same thing through the legacy v1alpha1 `machine:` fields is rejected as a conflict.
  # Patches below are documents matched by kind (strategic merge).
  common_patches = [
    <<-EOT
    apiVersion: v1alpha1
    kind: UnattendedInstallConfig
    installer:
      image: ${data.talos_image_factory_urls.this.urls.installer}
    provisioning:
      diskSelector:
        match: disk.dev_path == "/dev/vda"
    EOT
    ,
    # OPNsense is the VPC's DNS and NTP server (like the Route 53 Resolver and AWS Time Sync).
    # No search domain (ADR 0004): lab.macpro has a wildcard (*.lab.macpro -> the Gateway), so with
    # `search lab.macpro` and the pods' ndots:5 every short name became <name>.lab.macpro: github.com
    # resolved to 10.10.1.200 and Argo CD couldn't fetch the repo. A set `domains` list replaces the
    # DHCP-provided one; `domains: []` would too, but an empty list vanishes when the patch is merged.
    # cluster.local is harmless (pods search it anyway; it never reaches the wildcard). disableDefault
    # drops the one derived from the hostname. Lab names are always used fully qualified.
    <<-EOT
    apiVersion: v1alpha1
    kind: ResolverConfig
    nameservers:
      - address: ${local.net.private_gateway}
    searchDomains:
      domains:
        - cluster.local
      disableDefault: true
    EOT
    ,
    <<-EOT
    apiVersion: v1alpha1
    kind: TimeSyncConfig
    ntp:
      servers:
        - ${local.net.private_gateway}
    EOT
    ,
    # containerd trusts the lab root CA for the lab registry only (Harbor, ADR 0013), so pods can pull
    # registry.lab.macpro/... images. Narrower than a TrustedRootsConfig, which would trust it system-wide.
    <<-EOT
    apiVersion: v1alpha1
    kind: RegistryTLSConfig
    name: registry.lab.macpro
    ca: |
      ${indent(2, trimspace(file("${path.module}/../../k8s/platform/step-ca/config/root_ca.crt")))}
    EOT
    ,
    # The generated HostnameConfig uses `auto: stable`, which conflicts with a static hostname:
    # replace the whole document.
    <<-EOT
    apiVersion: v1alpha1
    kind: HostnameConfig
    $patch: delete
    EOT
    ,
  ]

  hostname_patch = { for name, _ in local.nodes : name => <<-EOT
    apiVersion: v1alpha1
    kind: HostnameConfig
    hostname: ${name}
    EOT
  }

  # Workers: the second disk (vdb) becomes a Talos user volume, mounted at /var/mnt/local-path-provisioner,
  # where local-path-provisioner creates PV directories (k8s/platform/local-path).
  worker_patches = [<<-EOT
    apiVersion: v1alpha1
    kind: UserVolumeConfig
    name: local-path-provisioner
    provisioning:
      diskSelector:
        match: disk.dev_path == "/dev/vdb"
      minSize: 1GiB
      grow: true
    filesystem:
      type: xfs
    EOT
  ]

  # Control plane only (these kinds are rejected on workers): no built-in CNI (Cilium instead)
  # and no kube-proxy (Cilium's kube-proxy replacement).
  controlplane_patches = [<<-EOT
    apiVersion: v1alpha1
    kind: KubeFlannelCNIConfig
    $patch: delete
    ---
    apiVersion: v1alpha1
    kind: KubeProxyConfig
    enabled: false
    EOT
  ]
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = var.talos_schematic_id
  platform      = "metal"
}

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = concat(
    local.common_patches,
    [local.hostname_patch[each.key]],
    each.value.role == "controlplane" ? local.controlplane_patches : local.worker_patches,
  )
}

resource "talos_machine_configuration_apply" "node" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = each.value.ip

  timeouts = {
    create = "10m"
  }
}

resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ip

  depends_on = [talos_machine_bootstrap.this]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for n in local.controlplanes : n.ip]
  nodes                = [for n in local.nodes : n.ip]
}

# Credentials land in the git-ignored .cache/cluster (never committed).
resource "local_sensitive_file" "kubeconfig" {
  filename        = "${local.out_dir}/kubeconfig"
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  file_permission = "0600"
}

resource "local_sensitive_file" "talosconfig" {
  filename        = "${local.out_dir}/talosconfig"
  content         = data.talos_client_configuration.this.talos_config
  file_permission = "0600"
}

# No talos_cluster_health here: Talos only reports "boot finished" once every node is Ready, which needs
# the CNI. Cilium is installed by scripts/bootstrap-cluster.sh, which then waits for all nodes Ready.
