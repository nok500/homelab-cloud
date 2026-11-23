output "subnets" {
  description = "VPC subnets and their OPNsense gateway."
  value       = { for s in local.subnets : s.name => { cidr = s.cidr, gateway = s.gateway, bridge = s.bridge } }
}

output "opnsense_wan_ip_file" {
  description = "File holding the WAN IPv4 OPNsense got via DHCP (written by the bootstrap step)."
  value       = "${local.cache_dir}/opnsense-wan.ip"
}

output "opnsense_root_password" {
  description = "OPNsense root password (web UI). SSH is key-only."
  value       = random_password.opnsense_root.result
  sensitive   = true
}

output "admin_cidrs" {
  description = "LAN sources allowed in through the OPNsense WAN (used by scripts/verify-host.sh)."
  value       = var.admin_cidrs
}

output "test_vm_mac" {
  value = var.enable_test_vm ? "52:54:00:10:01:10" : null
}

output "opnsense_host_alias" {
  description = "Name the pinned OPNsense host keys are recorded under in known_hosts."
  value       = local.opnsense_host_alias
}

output "ssh_opnsense" {
  description = "SSH to OPNsense with the pinned host key (WAN IP from the bootstrap step)."
  value       = "ssh -o HostKeyAlias=${local.opnsense_host_alias} -o UserKnownHostsFile=${local_file.known_hosts.filename} root@$(cat ${local.cache_dir}/opnsense-wan.ip)"
}

output "talos_nodes" {
  description = "Talos nodes (name -> role, IP, MAC), consumed by terraform/talos."
  value       = { for name, n in local.talos_nodes : name => { role = n.role, ip = n.ip, mac = n.mac } }
}

output "network" {
  description = "VPC facts consumed by terraform/talos (gateway = DNS and NTP for the nodes)."
  value = {
    domain          = var.domain
    private_cidr    = local.subnet["private"].cidr
    private_gateway = local.subnet["private"].gateway
    lb_ip_range     = { start = cidrhost(local.subnet["private"].cidr, 200), stop = cidrhost(local.subnet["private"].cidr, 220) }
  }
}
