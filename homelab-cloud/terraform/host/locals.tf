locals {
  repo_root = abspath("${path.module}/../..")
  cache_dir = "${local.repo_root}/.cache/host"

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))

  # The "VPC". Order matters: it is the NIC order on the OPNsense VM (vtnet1..3; vtnet0 is WAN).
  # OPNsense's "lan" interface is the private subnet, so its default allow-out rule covers it.
  subnet_defs = [
    { name = "private", cidr = "10.10.1.0/24", ifkey = "lan" },
    { name = "public", cidr = "10.10.0.0/24", ifkey = "opt1" },
    { name = "data", cidr = "10.10.2.0/24", ifkey = "opt2" },
  ]

  subnets = [for i, s in local.subnet_defs : merge(s, {
    ifname     = "vtnet${i + 1}"
    bridge     = "lbr-${s.name}"
    gateway    = cidrhost(s.cidr, 1)
    prefix     = split("/", s.cidr)[1]
    dhcp_start = cidrhost(s.cidr, 100)
    dhcp_end   = cidrhost(s.cidr, 199)
    # stable MACs keep DHCP leases and vtnet ordering predictable across rebuilds
    opnsense_mac = format("52:54:00:10:%02x:01", i + 1)
  })]

  subnet = { for s in local.subnets : s.name => s }

  wan_mac = "52:54:00:10:00:01"

  # ssh -o HostKeyAlias=<this> -o UserKnownHostsFile=.cache/host/known_hosts root@<wan ip>
  opnsense_host_alias = "opnsense.${var.domain}"

  # Firewall: each subnet may go anywhere (NAT out via WAN). From the WAN (home LAN) only
  # admin_cidrs get in, and only to OPNsense SSH/HTTPS plus SSH/ICMP into the private subnet.
  egress_rules = [for i, s in local.subnets : {
    sequence    = i + 1
    interface   = s.ifkey
    protocol    = "any"
    source      = s.ifkey
    destination = "any"
    port        = ""
    log         = false
    replyto     = true
    description = "${s.name}: allow out"
  }]

  # replyto = false: admin_cidrs sit on the WAN's own subnet, so replies must go straight back
  # on the LAN instead of being forced via the WAN gateway (OPNsense's default reply-to).
  # Ports admin_cidrs may reach in the private subnet: SSH (test VM), Kubernetes API, Talos API,
  # and the Cilium Gateway (HTTP/HTTPS on the LB IPs).
  admin_private_ports = {
    "22"    = "SSH"
    "6443"  = "Kubernetes API"
    "50000" = "Talos API"
    "80"    = "Gateway HTTP"
    "443"   = "Gateway HTTPS"
  }

  admin_rules = flatten([for i, cidr in var.admin_cidrs : concat(
    [
      { sequence = 100 + i * 20, interface = "wan", protocol = "TCP", source = cidr, destination = "(self)", port = "22", log = false, replyto = false, description = "admin ${cidr}: SSH to firewall" },
      { sequence = 101 + i * 20, interface = "wan", protocol = "TCP", source = cidr, destination = "(self)", port = "443", log = false, replyto = false, description = "admin ${cidr}: web UI/API" },
      { sequence = 102 + i * 20, interface = "wan", protocol = "ICMP", source = cidr, destination = "(self)", port = "", log = false, replyto = false, description = "admin ${cidr}: ping firewall" },
      { sequence = 103 + i * 20, interface = "wan", protocol = "ICMP", source = cidr, destination = "lan", port = "", log = false, replyto = false, description = "admin ${cidr}: ping private" },
    ],
    [for j, port in keys(local.admin_private_ports) : {
      sequence = 104 + i * 20 + j, interface = "wan", protocol = "TCP", source = cidr, destination = "lan", port = port,
      log      = port == "22", replyto = false, description = "admin ${cidr}: ${local.admin_private_ports[port]} into private"
    }],
  )])

  # Talos nodes: fixed IPs on the private subnet via DHCP reservations (MAC -> IP), so the
  # nodes boot into maintenance mode at a known address and terraform/talos can configure them.
  talos_nodes = { for name, n in var.talos_nodes : name => merge(n, {
    ip  = cidrhost(local.subnet["private"].cidr, n.host_number)
    mac = format("52:54:00:10:01:%02x", n.host_number)
  }) }

  static_hosts = [for name, n in local.talos_nodes : { name = name, ip = n.ip, mac = n.mac, descr = "talos ${n.role}" }]

  opnsense_config = templatefile("${path.module}/templates/opnsense-config.xml.tftpl", {
    opnsense_version         = var.opnsense_version
    hostname                 = "opnsense"
    domain                   = var.domain
    timezone                 = var.timezone
    root_password_hash       = random_password.opnsense_root.bcrypt_hash
    root_authorized_keys_b64 = base64encode("${local.ssh_public_key}\n")
    subnets                  = local.subnets
    rules                    = concat(local.egress_rules, local.admin_rules)
    static_hosts             = local.static_hosts
    ntp_server               = var.ntp_server
    upstream_dns             = var.upstream_dns
  })
}
