# "EKS" nodes: Talos VMs on the private subnet. They boot the metal image into maintenance mode,
# get their fixed IP from the OPNsense DHCP reservation (MAC -> IP, see locals.talos_nodes), and are
# then configured and bootstrapped by terraform/talos.
resource "libvirt_volume" "talos_base" {
  name = basename(var.images.talos)
  pool = libvirt_pool.lab.name

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = {
      url = "${local.repo_root}/${var.images.talos}"
    }
  }
}

resource "libvirt_volume" "talos_disk" {
  for_each = local.talos_nodes

  name     = "${each.key}.qcow2"
  pool     = libvirt_pool.lab.name
  capacity = var.vm_sizes[each.value.role].disk * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.talos_base.path
    format = { type = "qcow2" }
  }
}

# Workers get a second disk for persistent volumes: Talos formats it as the `local-path-provisioner`
# user volume (/var/mnt/local-path-provisioner, see terraform/talos), kept apart from the system disk so
# PVs can't fill EPHEMERAL (containerd, logs) and starve the node.
resource "libvirt_volume" "talos_data" {
  for_each = { for name, n in local.talos_nodes : name => n if n.role == "worker" }

  name     = "${each.key}-data.qcow2"
  pool     = libvirt_pool.lab.name
  capacity = var.worker_data_disk_gb * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }
}

resource "libvirt_domain" "talos" {
  for_each = local.talos_nodes

  name        = each.key
  type        = "kvm"
  vcpu        = var.vm_sizes[each.value.role].vcpu
  memory      = var.vm_sizes[each.value.role].memory
  memory_unit = "MiB"
  autostart   = true
  running     = true

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  # host-passthrough: Talos amd64 needs x86-64-v2, which generic QEMU CPU models don't advertise
  cpu = {
    mode = "host-passthrough"
  }

  features = {
    acpi = true
  }

  devices = {
    disks = concat(
      [{
        source = { volume = { pool = libvirt_volume.talos_disk[each.key].pool, volume = libvirt_volume.talos_disk[each.key].name } }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2" }
      }],
      each.value.role == "worker" ? [{
        source = { volume = { pool = libvirt_volume.talos_data[each.key].pool, volume = libvirt_volume.talos_data[each.key].name } }
        target = { bus = "virtio", dev = "vdb" }
        driver = { type = "qcow2" }
      }] : [],
    )

    interfaces = [{
      model  = { type = "virtio" }
      mac    = { address = each.value.mac }
      source = { network = { network = libvirt_network.subnet["private"].name } }
    }]

    serials = [{
      target = { port = 0 }
    }]

    consoles = [{
      target = { type = "serial", port = 0 }
    }]

    # virtio-serial channel for the qemu-guest-agent extension baked into the schematic
    # (`virsh domifaddr --source agent`, clean `virsh shutdown`); libvirt picks the socket path.
    channels = [{
      source = { unix = { mode = "bind" } }
      target = { virt_io = { name = "org.qemu.guest_agent.0" } }
    }]

    # libvirt adds no video device by default (-nodefaults); bootloaders can hang without one
    videos = [{
      model = { type = "vga" }
    }]
  }

  # DHCP reservations must exist before the nodes ask for a lease
  depends_on = [terraform_data.opnsense_bootstrap]

  lifecycle {
    # a rebuilt OPNsense means a fresh VPC: rebuild the nodes too
    replace_triggered_by = [terraform_data.opnsense_bootstrap]
  }
}
