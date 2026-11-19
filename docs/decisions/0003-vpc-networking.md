# 0003: VPC networking: isolated libvirt bridges + OPNsense, macvtap WAN

- Status: accepted
- Date: 2026-11-19

## Context

The lab needs AWS-style public/private/data subnets with one router doing NAT and filtering, on a
host that already runs UFW and Docker (both manage netfilter). The brief forbids touching the host's
bridge/firewall config without approval, or anything that risks the SSH session.

## Decision

| Piece | Choice |
|---|---|
| Subnets | `10.10.0.0/24` public, `10.10.1.0/24` private, `10.10.2.0/24` data. Isolated libvirt networks (`lab-*`, bridges `lbr-*`) with **no host IP**, no libvirt DHCP/NAT |
| Router | OPNsense 26.7 (nano image) is `.1` on every subnet: DHCP (dnsmasq), DNS (Unbound), outbound NAT, pf firewall |
| WAN | **macvtap (bridge mode) on `enp12s0`**: OPNsense gets its own DHCP lease on the home LAN |
| LAN → lab | Static route `10.10.0.0/16 via <OPNsense WAN>` on the admin workstation only (`make route`) |
| Ingress policy | WAN default deny. `admin_cidrs` may reach OPNsense SSH/HTTPS/ICMP and the private subnet SSH/ICMP. WAN "block private networks" is off, since the WAN *is* an RFC1918 LAN |

## Why

- **Zero host changes.** macvtap and the isolated bridges are created and removed by libvirt; the host's
  `enp12s0`, UFW rules and Docker are untouched. With no host IP on the lab bridges, and `br_netfilter` not loaded,
  lab traffic never enters the host's netfilter, so there's no interaction with Docker's `FORWARD DROP` policy.
- **Same shape as AWS.** One router per VPC; subnets only reach each other and the outside through it;
  ingress is opt-in per source and port, like security groups and NACLs.

## Trade-offs

- **macvtap host isolation**: the Mac Pro itself cannot talk to OPNsense's WAN address (traffic between a
  macvtap guest and its parent NIC's host is not looped back). Everything is managed from the workstation,
  so this doesn't matter today. If the host ever needs lab access, add a host-side libvirt network or use the
  spare NIC `enp11s0`.
- **Static route on one machine** keeps the home router untouched but means other LAN devices can't reach
  the lab. Revisit in Phase 2 together with `*.lab.home` DNS.
- The WAN IP comes from the home router's DHCP. A fixed MAC (`52:54:00:10:00:01`) keeps the lease stable
  across rebuilds.

## Bootstrap (OPNsense has no cloud-init)

Terraform renders `config.xml` (interfaces, DHCP ranges, rules, root password hash, SSH key) and the SSH host
keys into an ISO 9660 image attached as a CD-ROM. The VM is created **stopped**, then
`scripts/opnsense-console-import.py` runs `virsh start --console` and answers the built-in
`opnsense-importer` prompt that every OPNsense image shows on boot when no config exists. Later boots skip it.
Details and gotchas are in the script and [runbooks/opnsense.md](../runbooks/opnsense.md).
