# VPC subnets as isolated libvirt networks: L2 only, no host IP, no libvirt DHCP/NAT/firewall rules.
# OPNsense is the only router on them, so lab traffic never traverses the host's UFW/Docker netfilter
# (br_netfilter is not loaded on the host; see docs/decisions/0003-vpc-networking.md).
resource "libvirt_network" "subnet" {
  for_each = local.subnet

  name      = "lab-${each.key}"
  autostart = true

  bridge = {
    name = each.value.bridge
    stp  = "on"
  }
}
