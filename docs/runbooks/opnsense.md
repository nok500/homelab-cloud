# Runbook: OPNsense (VPC router)

## Access

```sh
eval "$(terraform -chdir=terraform/host output -raw ssh_opnsense)"            # SSH, pinned host key
terraform -chdir=terraform/host output -raw opnsense_root_password            # web UI password
virsh -c qemu+ssh://macpro/system console opnsense                            # serial console (Ctrl-] exits)
```

Web UI: `https://<WAN IP>/` from an `admin_cidrs` source (WAN IP in `.cache/host/opnsense-wan.ip`).

## Connectivity loss: find the hop, then recover

Everything in the lab is reached through OPNsense, so "nothing answers" can be any hop between voodoo and the
VMs. Find the first broken hop before restarting anything.

### 1. Diagnose (from voodoo, in order)

| # | Check | Healthy | If not |
|---|---|---|---|
| 1 | `ping -c1 192.168.8.207` | reply | **Host** is down or off the network: power, fans, cables, switch. `ip neigh show 192.168.8.207` showing `INCOMPLETE` means no ARP at all. Nothing below matters until this works. `make temps` once it's back |
| 2 | `ip route get 10.10.1.20` | `via 192.168.8.115` | `make route` (gone after every voodoo reboot). Without it, Terraform hangs at `talos_machine_configuration_apply … Still creating…` |
| 3 | `ssh macpro virsh -c qemu:///system list --all` | all `running` | `virsh -c qemu:///system start <vm>` (autostart covers normal host boots) |
| 4 | `ssh macpro ip -br link show enp11s0` | `UP … LOWER_UP` | Reseat the 2nd NIC cable; macvtap recovers when the carrier returns |
| 5 | `ping -c1 192.168.8.115` | reply | OPNsense itself: see the ladder below |
| 6 | `ping -c1 10.10.1.20`, `make verify` | all PASS | Firewall rules, Talos or the Gateway: [cluster-access.md](cluster-access.md) |

The host can't reach OPNsense's WAN itself (macvtap doesn't hairpin to its own parent), so always test from
voodoo, not from the Mac Pro.

### 2. Recovery ladder (stop at the first that works)

| Step | Command | Use when | Cost |
|---|---|---|---|
| 1. Renew WAN | SSH (see Access), then `configctl interface reconfigure wan` | WAN lost its lease, e.g. after a router reboot. The IP stays `.115` (fixed MAC) | seconds |
| 2. Reload services | `configctl service reload all`, or console menu option 11 | WAN fine, but DNS, NAT or DHCP misbehave | seconds |
| 3. Reboot the VM | `virsh -c qemu+ssh://macpro/system reboot opnsense` | SSH answers but things are wedged | 60–90 s |
| 4. Hard reset | `virsh -c qemu+ssh://macpro/system reset opnsense` | No SSH, no console response | 60–90 s |
| 5. Rebuild | `make destroy && make up` | Doesn't boot (below), or the config is broken | ~6.5 min; rebuilds the Talos nodes too (`replace_triggered_by`) |

During steps 3–4 the Talos nodes keep running and keep their reserved IPs. Pods lose egress and DNS until
OPNsense is back; in-cluster traffic keeps working. The config lives on OPNsense's disk, so a reboot or reset
doesn't re-import anything.

No SSH over the WAN: use the serial console (`virsh -c qemu+ssh://macpro/system console opnsense`, Ctrl-] exits).
It needs the host up.

### 3. OPNsense doesn't boot after a host reboot

Seen on 2026-11-20 after the Mac Pro rebooted. `libvirt-guests` was disabled, so the VMs were killed rather
than shut down, which is a power cut for OPNsense's UFS disk. Signature:

- 100 % of its vCPU, the serial console silent (no reaction to Enter or Ctrl-T), WAN and `10.10.1.1` down.
- The disk is barely touched: `virsh domblkstat opnsense vda` shows about 16 reads and 0 writes.
- `virsh qemu-monitor-command opnsense --hmp 'info registers'` shows `EIP=000093xx` (not `RIP`), and `CR0`
  flips between `…11` and `…10`. That's the FreeBSD BTX boot monitor making BIOS calls in a loop:
  `gptboot` couldn't load `/boot/loader` and sits at its `boot:` prompt. That stage prints to VGA, which this
  VM doesn't have, so it's invisible on serial.

Fix: rebuild (ladder step 5). The disk holds nothing that isn't in Terraform. Prevention: stop the lab with
`make shutdown` / `make poweroff` before any host shutdown ([power.md](power.md)), plus this safety net, once on
the host (the user runs it, since sudo is needed):

```sh
# Arch ships no /etc/conf.d/libvirt-guests (the unit's EnvironmentFile is optional): create it.
# Without it the default is ON_SHUTDOWN=suspend (RAM saved to disk, resumed with a stale clock).
sudo tee /etc/conf.d/libvirt-guests >/dev/null <<'CONF'
URIS=qemu:///system
ON_BOOT=ignore            # VMs come back via libvirt autostart (set by Terraform)
ON_SHUTDOWN=shutdown      # ACPI shutdown, not suspend/kill
PARALLEL_SHUTDOWN=4       # all VMs at once
SHUTDOWN_TIMEOUT=120      # then force off whatever is left
CONF
sudo systemctl enable --now libvirt-guests   # shows "active (exited)": it only acts at shutdown
```

Other debugging sources: `sudo tail -50 /var/log/libvirt/qemu/opnsense.log` on the host;
`sudo qemu-img check -U /var/lib/libvirt/pools/homelab/opnsense.qcow2`; and, once it boots,
`/var/log/system/latest.log` and `dmesg -a` inside OPNsense.

## How the first boot works

1. Terraform renders `config.xml` from `terraform/host/templates/opnsense-config.xml.tftpl`, plus all three SSH
   host keys, into `.cache/host/opnsense-iso/conf/` and packs it as an ISO 9660 CD-ROM.
2. The domain is defined **stopped**. `scripts/opnsense-console-import.py` runs
   `virsh start opnsense --console`, so it's on the serial port before the first byte of boot output.
3. At `Press any key to start the configuration importer` (7 s countdown) it sends a key, then answers `cd0`.
4. It waits for the banner, parses `WAN (vtnet0) -> v4/DHCP4: <ip>` and writes `.cache/host/opnsense-wan.ip`.

Any change to the template or keys replaces the ISO, the disk and the VM (a fresh import), plus the test VM.

## Gotchas found while building this

| Symptom | Cause | Fix in repo |
|---|---|---|
| `No known partition layout was found for 'cd0'` | The importer runs before CAM has attached the CD (`camcontrol` shows `()`) | Script retries every 3 s; typically succeeds on attempt 4 |
| No `login:` on serial after import | `config.xml.sample` has no `primaryconsole`; the nano image's own default sets serial | `<primaryconsole>serial</primaryconsole>` in template |
| SSH host key changes on every rebuild despite shipping one | 26.7 regenerates **all** host keys if any of rsa/ecdsa/ed25519 is missing | Terraform generates all three |
| Terraform wants to replace the bootstrap step after apply | In `dmacvicar/libvirt` 0.9 `id` is the runtime domain ID (null when off) | Trigger on `uuid`; `ignore_changes = [running]` |
| Replies to the workstation go via the home router (`reply-to (vtnet0 192.168.8.1)` in `pfctl -sr`) | OPNsense adds reply-to on WAN rules by default; the admin workstation is on the WAN's own subnet | `disablereplyto` on the admin rules |
| Host got a 2nd IP + 2nd default route when `enp11s0` was cabled | Stock `20-ethernet.network` DHCPs every Ethernet port | `10-lab-uplink.network` (bootstrap.md §2) |
| Debian test VM reboot-loops right after GRUB | libvirt uses `-nodefaults`, so there's no VGA at all, and the Debian cloud GRUB/kernel needs one | `videos = [{ model = { type = "vga" } }]` |

## Rules (seeded via config.xml)

| # | Interface | Source | Destination | Port | Purpose |
|---|---|---|---|---|---|
| 1–3 | private/public/data | that subnet | any | any | egress (NAT on WAN) |
| 100+ | WAN | each `admin_cidrs` entry | firewall | 22, 443, ICMP | management |
| 103 | WAN | each `admin_cidrs` entry | private net | ICMP | ping VMs / nodes |
| 104+ | WAN | each `admin_cidrs` entry | private net | 22 (logged), 6443, 50000, 80, 443 | SSH, Kubernetes API, Talos API, Gateway HTTP/HTTPS (`admin_private_ports` in `terraform/host/locals.tf`) |

Everything else inbound on WAN hits the default deny. Rule management moves to the
`browningluke/opnsense` Terraform provider once an API key is provisioned (open item).
