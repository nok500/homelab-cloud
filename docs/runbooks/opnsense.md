# Runbook: OPNsense (VPC router)

## Access

```sh
eval "$(terraform -chdir=terraform/host output -raw ssh_opnsense)"            # SSH, pinned host key
terraform -chdir=terraform/host output -raw opnsense_root_password            # web UI password
virsh -c qemu+ssh://macpro/system console opnsense                            # serial console (Ctrl-] exits)
```

Web UI: `https://<WAN IP>/` from an `admin_cidrs` source (WAN IP in `.cache/host/opnsense-wan.ip`).

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
| Debian test VM reboot-loops right after GRUB | libvirt uses `-nodefaults`, so there's no VGA at all, and the Debian cloud GRUB/kernel needs one | `videos = [{ model = { type = "vga" } }]` |

## Rules (seeded via config.xml)

| # | Interface | Source | Destination | Port | Purpose |
|---|---|---|---|---|---|
| 1–3 | private/public/data | that subnet | any | any | egress (NAT on WAN) |
| 100+ | WAN | each `admin_cidrs` entry | firewall | 22, 443, ICMP | management |
| 103+ | WAN | each `admin_cidrs` entry | private net | 22 (logged), ICMP | admin access to VMs |

Everything else inbound on WAN hits the default deny. Rule management moves to the
`browningluke/opnsense` Terraform provider once an API key is provisioned (Phase 2).
