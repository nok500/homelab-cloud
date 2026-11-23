resource "random_password" "opnsense_root" {
  length  = 24
  special = false
}

# --- config.xml -> ISO 9660 image, imported once on first boot ------------------------------
resource "local_sensitive_file" "opnsense_config" {
  filename        = "${local.cache_dir}/opnsense-iso/conf/config.xml"
  content         = local.opnsense_config
  file_permission = "0600"
}

# Stable SSH host keys: the importer restores /conf/sshd from the ISO, so rebuilds keep the
# same identity and known_hosts can be pinned instead of trust-on-first-use.
# All three types are required: OPNsense 26.7 regenerates *every* host key if any one is missing.
locals {
  ssh_host_key_types = {
    rsa     = { algorithm = "RSA", rsa_bits = 3072, ecdsa_curve = null }
    ecdsa   = { algorithm = "ECDSA", rsa_bits = null, ecdsa_curve = "P256" }
    ed25519 = { algorithm = "ED25519", rsa_bits = null, ecdsa_curve = null }
  }
}

resource "tls_private_key" "opnsense_ssh_host" {
  for_each = local.ssh_host_key_types

  algorithm   = each.value.algorithm
  rsa_bits    = each.value.rsa_bits
  ecdsa_curve = each.value.ecdsa_curve
}

resource "local_sensitive_file" "opnsense_ssh_host_key" {
  for_each = tls_private_key.opnsense_ssh_host

  filename        = "${local.cache_dir}/opnsense-iso/conf/sshd/ssh_host_${each.key}_key"
  content         = each.value.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "opnsense_ssh_host_key_pub" {
  for_each = tls_private_key.opnsense_ssh_host

  filename        = "${local.cache_dir}/opnsense-iso/conf/sshd/ssh_host_${each.key}_key.pub"
  content         = each.value.public_key_openssh
  file_permission = "0644"
}

resource "local_file" "known_hosts" {
  filename = "${local.cache_dir}/known_hosts"
  content = join("", [for k in tls_private_key.opnsense_ssh_host :
  "${local.opnsense_host_alias} ${trimspace(k.public_key_openssh)}\n"])
}

resource "terraform_data" "opnsense_iso" {
  triggers_replace = concat(
    [sha256(local.opnsense_config)],
    [for k in tls_private_key.opnsense_ssh_host : sha256(k.private_key_openssh)],
  )

  provisioner "local-exec" {
    command = "genisoimage -quiet -r -V OPNCONF -o '${local.cache_dir}/opnsense-config.iso' '${local.cache_dir}/opnsense-iso'"
  }

  depends_on = [local_sensitive_file.opnsense_config, local_sensitive_file.opnsense_ssh_host_key, local_file.opnsense_ssh_host_key_pub]
}

resource "libvirt_volume" "opnsense_config" {
  name = "opnsense-config.iso"
  pool = libvirt_pool.lab.name

  create = {
    content = {
      url = "${local.cache_dir}/opnsense-config.iso"
    }
  }

  lifecycle {
    replace_triggered_by = [terraform_data.opnsense_iso]
  }
}

# --- disks -------------------------------------------------------------------------------
resource "libvirt_volume" "opnsense_base" {
  name = basename(var.images.opnsense)
  pool = libvirt_pool.lab.name

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = {
      url = "${local.repo_root}/${var.images.opnsense}"
    }
  }
}

resource "libvirt_volume" "opnsense_disk" {
  name     = "opnsense.qcow2"
  pool     = libvirt_pool.lab.name
  capacity = var.vm_sizes.opnsense.disk * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.opnsense_base.path
    format = { type = "qcow2" }
  }

  # A new config must be imported onto a fresh disk (the importer only runs when none exists).
  lifecycle {
    replace_triggered_by = [terraform_data.opnsense_iso]
  }
}

# --- VM ----------------------------------------------------------------------------------
resource "libvirt_domain" "opnsense" {
  name        = "opnsense"
  type        = "kvm"
  vcpu        = var.vm_sizes.opnsense.vcpu
  memory      = var.vm_sizes.opnsense.memory
  memory_unit = "MiB"
  autostart   = true

  # Started by the bootstrap step below with the console attached, so the importer prompt is not missed.
  running = false

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  cpu = {
    mode = "host-passthrough"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = [
      {
        source = { volume = { pool = libvirt_volume.opnsense_disk.pool, volume = libvirt_volume.opnsense_disk.name } }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2" }
      },
      {
        device = "cdrom"
        source = { volume = { pool = libvirt_volume.opnsense_config.pool, volume = libvirt_volume.opnsense_config.name } }
        target = { bus = "sata", dev = "sda" }
      },
    ]

    interfaces = concat(
      [{
        model  = { type = "virtio" }
        mac    = { address = local.wan_mac }
        source = { direct = { dev = var.wan_parent_interface, mode = "bridge" } }
      }],
      [for s in local.subnets : {
        model  = { type = "virtio" }
        mac    = { address = s.opnsense_mac }
        source = { network = { network = libvirt_network.subnet[s.name].name } }
      }],
    )

    serials = [{
      target = { port = 0 }
    }]

    consoles = [{
      target = { type = "serial", port = 0 }
    }]
  }

  lifecycle {
    replace_triggered_by = [terraform_data.opnsense_iso]
    # `running = false` only matters at creation (the bootstrap step starts it with the console
    # attached); afterwards libvirt reports it running and autostart keeps it that way.
    ignore_changes = [running]
  }
}

# First boot: start the VM attached to its serial console and drive the config importer.
resource "terraform_data" "opnsense_bootstrap" {
  # uuid, not id: in this provider `id` is libvirt's runtime domain ID (null while shut off).
  triggers_replace = [libvirt_domain.opnsense.uuid]

  provisioner "local-exec" {
    command = join(" ", [
      "python3 '${local.repo_root}/scripts/opnsense-console-import.py'",
      "--device cd0",
      "--log '${local.cache_dir}/opnsense-console.log'",
      "--wan-ip-file '${local.cache_dir}/opnsense-wan.ip'",
      "-- virsh -c '${replace(var.libvirt_uri, "+sshcmd", "+ssh")}' start ${libvirt_domain.opnsense.name} --console",
    ])
  }
}
