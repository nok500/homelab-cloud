# 0004: Lab DNS: `lab.macpro`, OPNsense Unbound, AdGuard wildcard rewrite

- Status: accepted (implemented in Phase 2)
- Date: 2026-11-19

## Context

Lab services (Argo CD, Grafana, Harbor, …) need stable names for the LAN and for TLS certificates. The home
LAN already runs AdGuard Home, which the brief says must not be reconfigured without the owner's approval.

## Decision

- **Zone:** `lab.macpro` (owner's choice; the lab lives on the Mac Pro). OPNsense is `opnsense.lab.macpro`,
  and DHCP clients in the VPC get `lab.macpro` as their search domain.
- **Inside the VPC:** OPNsense Unbound answers `lab.macpro` itself and **forwards everything else to AdGuard
  Home at `192.168.8.1:53`** (web UI on `:3000`), instead of recursing from the root servers. Lab DNS then gets the home filtering and logging.
  This needs no change in AdGuard.
- **From the LAN:** a single **DNS rewrite** in AdGuard, `*.lab.macpro → <Cilium Gateway LB IP>` (option a).
  Every service goes through the one Gateway, which routes by hostname. The owner adds this entry by hand
  once the Gateway IP exists; the exact entry goes in `docs/bootstrap.md`.

- **Time (same Phase 2 change):** the home router doesn't serve NTP, so OPNsense syncs from the ntp.org pool
  (`uk.pool.ntp.org`, one pool instead of the four `opnsense.pool.ntp.org` defaults) and serves NTP to the VPC.
  Talos nodes use their subnet gateway `10.10.x.1` as time server, like EC2 using the AWS Time Sync Service.

Checked 2026-11-19 from OPNsense: AdGuard answers (`drill @192.168.8.1`), filtering is active
(`doubleclick.net → 0.0.0.0`), 1–25 ms per query once warm.

## Alternatives considered

- **Conditional forwarding** `[/lab.macpro/]<OPNsense WAN>` in AdGuard: the lab is authoritative for its own
  zone (like a Route 53 private hosted zone) and can have per-host records from Git (ExternalDNS). It needs a WAN
  rule for DNS from AdGuard. Deferred until per-host records are needed.
- **`home.arpa`** (RFC 8375, the reserved name for home networks): standards-friendly, but the owner prefers
  `lab.macpro`. `.macpro` is not a delegated TLD, so it resolves only via AdGuard and Unbound, which is fine for a
  private lab.

## Consequences

- LAN devices resolve `*.lab.macpro`, but can only connect if they have a route to `10.10.0.0/16`. Today that's only
  the admin workstation (`make route`); a static route on the home router is a separate decision.
- cert-manager and step-ca (Phase 3) issue certificates for `*.lab.macpro`.
