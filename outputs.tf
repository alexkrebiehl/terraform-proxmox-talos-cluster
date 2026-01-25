output "kubeconfig_yaml" {
  description = "Kubeconfig for cluster access"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talosconfig_yaml" {
  description = "Talosconfig for talosctl access"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "cp_ip_addresses" {
  description = "IP addresses of control plane nodes"
  value       = local.cp_ips
}

output "worker_ip_addresses" {
  description = "IP addresses of worker nodes"
  value       = local.worker_ips
}

output "cluster_vip" {
  description = "Virtual IP for control plane (empty if not configured)"
  value       = var.cluster_vip
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = local.cluster_endpoint
}
