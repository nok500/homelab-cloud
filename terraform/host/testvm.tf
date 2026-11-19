# Phase 1 verification VM: Debian on the private subnet, DHCP from OPNsense, internet via OPNsense NAT.
resource "libvirt_volume" "debian_base" {
  count = var.enable_test_vm ? 1 : 0

  name = basename(var.images.debian)
  pool = libvirt_pool.lab.name

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = {
      url = "${local.repo_root}/${var.images.debian}"
    }
  }
}

resource "libvirt_volume" "testvm_disk" {
  count = var.enable_test_vm ? 1 : 0

  name     = "testvm.qcow2"
  pool     = libvirt_pool.lab.name
  capacity = var.vm_sizes.testvm.disk * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.debian_base[0].path
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "testvm" {
  count = var.enable_test_vm ? 1 : 0

  name = "testvm-cloudinit"

  meta_data = <<-EOF
    instance-id: testvm-1
    local-hostname: testvm
  EOF

  user_data = <<-EOF
    #cloud-config
    users:
      - name: debian
        groups: [sudo]
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: true
        ssh_authorized_keys:
          - ${local.ssh_public_key}
    ssh_pwauth: false
  EOF

  network_config = <<-EOF
    version: 2
    ethernets:
      primary:
        match:
          macaddress: "52:54:00:10:01:10"
        dhcp4: true
  EOF
}

resource "libvirt_volume" "testvm_cloudinit" {
  count = var.enable_test_vm ? 1 : 0

  name = "testvm-cloudinit.iso"
  pool = libvirt_pool.lab.name

  create = {
    content = {
      url = libvirt_cloudinit_disk.testvm[0].path
    }
  }
}

resource "libvirt_domain" "testvm" {
  count = var.enable_test_vm ? 1 : 0

  name        = "testvm"
  type        = "kvm"
  vcpu        = var.vm_sizes.testvm.vcpu
  memory      = var.vm_sizes.testvm.memory
  memory_unit = "MiB"
  running     = true

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
        source = { volume = { pool = libvirt_volume.testvm_disk[0].pool, volume = libvirt_volume.testvm_disk[0].name } }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2" }
      },
      {
        device = "cdrom"
        source = { volume = { pool = libvirt_volume.testvm_cloudinit[0].pool, volume = libvirt_volume.testvm_cloudinit[0].name } }
        target = { bus = "sata", dev = "sda" }
      },
    ]

    interfaces = [{
      model  = { type = "virtio" }
      mac    = { address = "52:54:00:10:01:10" }
      source = { network = { network = libvirt_network.subnet["private"].name } }
    }]

    serials = [{
      target = { port = 0 }
    }]

    consoles = [{
      target = { type = "serial", port = 0 }
    }]

    # Required: libvirt runs QEMU with -nodefaults, and the Debian cloud image's GRUB
    # reboot-loops before the kernel prints anything when there is no VGA adapter at all.
    videos = [{
      model = { type = "vga" }
    }]
  }

  # OPNsense must be up (DHCP) before the test VM boots, and a rebuilt OPNsense (empty lease
  # table) means the test VM is rebuilt too, so the verification always sees a fresh lease.
  depends_on = [terraform_data.opnsense_bootstrap]

  lifecycle {
    replace_triggered_by = [terraform_data.opnsense_bootstrap]
  }
}
