# Bootstrap (manual, one-time steps)

Everything after these steps is code. Keep this list as short as possible.

## 0. Workstation (where you run `make`)

Requirements: `git`, `make`, `python3`, `curl`, `terraform` ≥ 1.15, SSH key access to the lab host.

```sh
make hooks   # installs pinned tflint, gitleaks and pre-commit into ./.tools, then installs the git hooks
make lint
```

## 1. Lab host: hypervisor (Phase 1)

Run on the Mac Pro as a sudo-capable user:

```sh
sudo pacman -S --needed qemu-base libvirt dnsmasq edk2-ovmf openbsd-netcat
sudo usermod -aG libvirt "$USER"           # lets Terraform use qemu:///system over SSH without sudo
sudo systemctl enable --now libvirtd.socket
```

Then log out and back in (for the group), and check:

```sh
virsh -c qemu:///system list --all
virt-host-validate qemu
```

Notes:

- `openbsd-netcat` is required by the Terraform libvirt provider's `qemu+ssh://` transport.
- If libvirt defines the `default` NAT network (`virbr0`, 192.168.122.0/24), leave it **stopped**. The lab
  uses its own networks with OPNsense doing NAT:
  `sudo virsh net-autostart default --disable; sudo virsh net-destroy default`
- Installing libvirt does not touch UFW or the LAN interface, so the SSH session is safe.

## 2. Workstation: Phase 1 extras

- `genisoimage` (packs the OPNsense `config.xml` ISO), `qemu-img` (image conversion), `virsh` (libvirt client).
- `terraform/host/lab.auto.tfvars` (git-ignored), from `lab.auto.tfvars.example`: at least `admin_cidrs`.

```sh
make up       # images -> pool, networks, OPNsense (scripted first boot), test VM   (~2 min)
make route    # sudo: 10.10.0.0/16 via OPNsense WAN on this workstation (not persistent)
make verify   # Phase 1 acceptance checks
make destroy  # removes everything libvirt-side; the host is back to its pre-lab state
```
