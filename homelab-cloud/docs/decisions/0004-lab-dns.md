# 0004: Lab DNS: `lab.macpro`, OPNsense Unbound, AdGuard wildcard rewrite

- Status: accepted (implemented in Phase 2; amended 2026-11-21: the VPC resolves `lab.macpro` via AdGuard)
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
- **From the LAN:** a single **DNS rewrite** in AdGuard, `*.lab.macpro → 10.10.1.200` (the Cilium Gateway,
  option a). Every service goes through the one Gateway, which routes by hostname. Added by hand by the owner
  (done), documented in `docs/bootstrap.md`.

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
- cert-manager and step-ca issue the `*.lab.macpro` wildcard ([ADR 0007](0007-private-pki.md)).

## Amendment (2026-11-21): the VPC resolves `lab.macpro` like the LAN

Found while wiring CNPG backups (Phase 3 milestone 5): inside the VPC, **no** `*.lab.macpro` name resolved except
OPNsense's own. Unbound forwarded the whole zone to OPNsense's dnsmasq, which runs with `local=/lab.macpro/` and
knows only the DHCP host names, so `s3.lab.macpro` and `argocd.lab.macpro` came back NXDOMAIN to every pod.

- **Now:** Unbound forwards `lab.macpro` to AdGuard, the same answers the LAN gets (`*.lab.macpro` → the Gateway,
  `s3.lab.macpro` → Garage on the host). Each fixed-address host (`talos-cp-1`, the workers) keeps a more specific
  override to dnsmasq, so node names still resolve to the nodes. Dynamic DHCP leases (10.10.x.100–199) lose
  their names, which nothing uses.
- Unbound's rebind protection doesn't strip the private answers: `lab.macpro` is already a `private-domain`.
  Tested live with `unbound-control forward_add` before changing the template (and reverted).
- `make verify` section 2 checks it from a pod: `argocd.lab.macpro`, `s3.lab.macpro` and `talos-cp-1.lab.macpro`.
- Needed by: CNPG → `s3.lab.macpro` (milestone 5), Argo CD → `sso.lab.macpro` for OIDC (milestone 6, [ADR 0012](0012-identity-keycloak.md)).
- **No `lab.macpro` search domain** (found on the first rebuild with this change): DHCP handed out
  `search lab.macpro`, and pods search with `ndots:5`, so every short external name was tried as
  `<name>.lab.macpro` first. With the wildcard answering, `github.com` resolved to the Gateway and Argo CD
  couldn't fetch the repo. The Talos `ResolverConfig` now sets the search domains to `cluster.local` only, with
  `disableDefault: true`. `domains: []` would be the obvious value, but an empty list disappears when the config
  patch is merged. Lab names are always used fully qualified.
