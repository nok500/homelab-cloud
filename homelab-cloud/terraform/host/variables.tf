variable "libvirt_uri" {
  description = "libvirt connection URI. qemu+sshcmd uses the ssh binary, so ~/.ssh/config applies."
  type        = string
  default     = "qemu+sshcmd://macpro/system"
}

variable "wan_parent_interface" {
  description = "Host NIC the OPNsense WAN attaches to via macvtap (bridge mode). Dedicated uplink with no host IP (docs/bootstrap.md)."
  type        = string
  default     = "enp11s0"
}

variable "admin_cidrs" {
  description = "LAN sources allowed to reach OPNsense (SSH/HTTPS) and the private subnet (SSH/ICMP) through the WAN."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrnetmask(c))])
    error_message = "admin_cidrs must be a non-empty list of IPv4 CIDRs, e.g. [\"192.168.8.10/32\"]."
  }
}

variable "ssh_public_key_file" {
  description = "Public key installed for root on OPNsense and the default user on test VMs."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "pool_path" {
  description = "Directory on the host for the libvirt storage pool."
  type        = string
  default     = "/var/lib/libvirt/pools/homelab"
}

variable "domain" {
  description = "DNS domain for the lab."
  type        = string
  default     = "lab.macpro"
}

variable "timezone" {
  type    = string
  default = "Europe/London"
}

variable "worker_data_disk_gb" {
  description = "Size of each worker's persistent-volume disk (vdb, thin-provisioned qcow2)"
  type        = number
  default     = 40
}

variable "vm_sizes" {
  description = "Per-role VM sizing (ADR 0002). memory in MiB, disk in GiB."
  type = map(object({
    vcpu   = number
    memory = number
    disk   = number
  }))
  default = {
    opnsense     = { vcpu = 1, memory = 3072, disk = 8 } # routing/DNS/NTP only; OPNsense's documented minimum (2026-11-23)
    testvm       = { vcpu = 1, memory = 1024, disk = 10 }
    controlplane = { vcpu = 1, memory = 4096, disk = 20 }  # Talos health gate: CP needs >= 1698 MiB (ADR 0002)
    worker       = { vcpu = 2, memory = 10240, disk = 20 } # ADR 0002 log: 10 GiB from 2026-11-23 (host keeps ~4 GiB)
  }
}

variable "ntp_server" {
  description = "Single upstream NTP pool for OPNsense, which then serves time to the VPC."
  type        = string
  default     = "pool.ntp.org"
}

variable "upstream_dns" {
  description = "Resolver Unbound forwards non-lab names to (e.g. the home AdGuard). null = recurse from the root servers."
  type        = string
  default     = null
}

variable "talos_nodes" {
  description = "Talos VMs on the private subnet. host_number = last octet of the node IP (outside the .100-.199 DHCP pool and the .200-.220 LB pool)."
  type = map(object({
    role        = string # controlplane | worker
    host_number = number
  }))
  default = {
    "talos-cp-1"     = { role = "controlplane", host_number = 20 }
    "talos-worker-1" = { role = "worker", host_number = 21 }
    "talos-worker-2" = { role = "worker", host_number = 22 }
  }

  validation {
    condition     = alltrue([for n in values(var.talos_nodes) : contains(["controlplane", "worker"], n.role) && n.host_number >= 2 && n.host_number < 100])
    error_message = "role must be controlplane or worker; host_number must be 2-99."
  }
}

variable "enable_test_vm" {
  description = "Create the Phase 1 verification VM on the private subnet (off by default to keep 2 host threads free; make verify turns it on)."
  type        = bool
  default     = false
}

variable "images" {
  description = "Base images prepared by scripts/fetch-images.sh (paths relative to the repo root)."
  type = object({
    opnsense = string
    debian   = string
    talos    = string
  })
  default = {
    opnsense = ".cache/images/opnsense-26.7-nano-amd64.qcow2"
    debian   = ".cache/images/debian-13-genericcloud-amd64-20261116-2664.qcow2"
    talos    = ".cache/images/talos-1.14.6-metal-amd64.qcow2"
  }
}

variable "opnsense_version" {
  description = "Only used for labelling the generated config; must match images.opnsense."
  type        = string
  default     = "26.7"
}
