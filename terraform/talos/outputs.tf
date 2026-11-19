output "kubeconfig_path" {
  value = local_sensitive_file.kubeconfig.filename
}

output "talosconfig_path" {
  value = local_sensitive_file.talosconfig.filename
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "installer_image" {
  value = data.talos_image_factory_urls.this.urls.installer
}

output "lb_ip_range" {
  description = "Cilium LB IPAM pool on the private subnet (consumed by the Cilium values)."
  value       = local.net.lb_ip_range
}
