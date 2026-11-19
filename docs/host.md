# Lab host: Mac Pro (Late 2013)

Surveyed 2026-11-19 over SSH, read-only. Re-check with `make temps` and the commands at the bottom.

## Hardware

| | |
|---|---|
| Hostname | `macpro` |
| CPU | Intel Xeon E5-1620 v2 @ 3.70 GHz, 1 socket, 4 cores / 8 threads, VT-x |
| x86-64 level | Ivy Bridge-EP → supports **x86-64-v2** (required by Talos amd64 images) |
| RAM | 32 GB installed, **31.3 GiB** usable (`MemTotal: 32827652 kB`) |
| Disk | 1× 894 GB NVMe (`nvme0n1`): 1 GB vfat `/boot`, 893 GB ext4 `/` (**767 GB free**) |
| NICs | `enp12s0` (LAN, DHCP, 192.168.8.207/24), `enp11s0` (**unused, link down**) |
| GPU | Dual AMD FirePro (used by the llama.cpp Vulkan container) |

## Software

| | |
|---|---|
| OS / kernel | Arch Linux, `7.3.5-arch1-1` |
| KVM | `kvm_intel` loaded, **nested virtualization enabled** (`nested=Y`), `/dev/kvm` present |
| libvirt / QEMU | **not installed** (Phase 1 bootstrap, see [bootstrap.md](bootstrap.md)) |
| Firewall | **UFW active**; nftables/iptables/firewalld units inactive (UFW manages the rules) |
| Networking | systemd-networkd + systemd-resolved; Tailscale (`tailscale0`, 100.77.52.25) |
| Containers | Docker + containerd; 6 Docker bridges (`docker0`, `br-*`, 172.17–172.23.0.0/16) |
| Fan control | `mbpfan` |

### Existing workloads (do not disturb)

| Container | Port | Notes |
|---|---|---|
| `llama.cpp` (server-vulkan) | 8080 | RAM use depends on the loaded model, **the main competitor for lab RAM** |
| `sensors-macpro` | 1002 | temperature exporter |
| `glances` | - | monitoring |
| `dozzle` | 1001 | container logs |

### Address space already in use

Avoid these when picking lab subnets: `192.168.8.0/24` (LAN), `172.17.0.0/16`–`172.23.0.0/16` (Docker),
`100.64.0.0/10` (Tailscale CGNAT). Lab subnets will use **`10.10.0.0/16`** (see Phase 1).

## Thermals

`lm_sensors` is installed (`coretemp`). Check them with `make temps` or `scripts/host-temps.sh --watch`.

Load test: 8 × `sha256sum /dev/zero` for 90 s (all threads at 100 %), sampled every 10 s, abort at 85 °C.

| State | CPU package | Fan |
|---|---|---|
| Idle | 47–48 °C (cores 42–49 °C) | - |
| Full load, 10 s | 62 °C | |
| Full load, 90 s | **65 °C** (plateau reached at ~70 s) | 1495 RPM (min 1100 / max 2038) |
| 30 s after load | 50 °C | |

`high` = 91 °C, `crit` = 105 °C, so there's plenty of headroom on the CPU. The GPUs share the same heatsink, and
they weren't loaded during the test. Combining lab load with llama.cpp inference is the worst case, so re-check it once the
cluster is up.

## Implications for the lab

- **KVM + nested virt are ready**, so Talos VMs can run with `host-passthrough` CPU (needed for x86-64-v2).
- **RAM is the binding constraint**: 31.3 GiB total, minus ≥ 4 GiB host reserve, minus llama.cpp.
  See [ADR 0002](decisions/0002-vm-sizing.md).
- **CPU**: 8 threads, ≥ 2 reserved for the host, so 6 vCPUs are available before overcommit. libvirt can overcommit
  vCPUs safely for a lab.
- **Disk** is not a constraint (767 GB free on NVMe); one libvirt `dir` storage pool on `/` is fine.
- **Firewall risk**: UFW, Docker and libvirt all manage netfilter rules. libvirt's default NAT network
  (`virbr0`) is **not** used: OPNsense does NAT. Lab bridges will be isolated libvirt networks plus one uplink.
  The firewall design is decided in Phase 1, after reading the live ruleset.
- **Spare NIC `enp11s0`** could become a dedicated OPNsense WAN uplink to the LAN, so the lab never shares `enp12s0`
  (and the SSH session). This needs a cable and approval; it's an option for Phase 1.

## Not yet checked (needs sudo)

- `sudo ufw status verbose` and `sudo nft list ruleset`: exact firewall rules
- `sudo dmidecode -t memory`: DIMM layout (for a possible RAM upgrade; the Mac Pro 2013 takes up to 64/128 GB)
- `virt-host-validate qemu`: after libvirt is installed

## Reproduce

```sh
ssh macpro 'lscpu; free -h; lsblk; ip -br a; ip r; lsmod | grep kvm;
  cat /sys/module/kvm_intel/parameters/nested; systemctl is-active ufw; sensors'
```
