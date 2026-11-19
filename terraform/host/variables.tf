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

variable "vm_sizes" {
  description = "Per-role VM sizing (ADR 0002). memory in MiB, disk in GiB."
  type = map(object({
    vcpu   = number
    memory = number
    disk   = number
  }))
  default = {
    opnsense = { vcpu = 1, memory = 1024, disk = 8 }
    testvm   = { vcpu = 1, memory = 1024, disk = 10 }
  }
}

variable "enable_test_vm" {
  description = "Create the Phase 1 verification VM on the private subnet."
  type        = bool
  default     = true
}

variable "images" {
  description = "Base images prepared by scripts/fetch-images.sh (paths relative to the repo root)."
  type = object({
    opnsense = string
    debian   = string
  })
  default = {
    opnsense = ".cache/images/opnsense-26.7-nano-amd64.qcow2"
    debian   = ".cache/images/debian-13-genericcloud-amd64-20261116-2664.qcow2"
  }
}

variable "opnsense_version" {
  description = "Only used for labelling the generated config; must match images.opnsense."
  type        = string
  default     = "26.7"
}
