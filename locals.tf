locals {
  # Subnet prefix length from CIDR (e.g., 24 from "192.168.11.0/24")
  network_prefix_length = tonumber(split("/", var.network_cidr)[1])

  # Extract host number from first IP (last octet for /24 networks)
  cp_first_host     = tonumber(split(".", var.cp_first_ip)[3])
  worker_first_host = tonumber(split(".", var.worker_first_ip)[3])

  # Generate control plane IPs using cidrhost() for reliable IP arithmetic
  cp_ips = [for i in range(var.cp_count) : cidrhost(var.network_cidr, local.cp_first_host + i)]

  # Generate worker IPs using cidrhost()
  worker_ips = [for i in range(var.worker_count) : cidrhost(var.network_cidr, local.worker_first_host + i)]

  # VIP configuration
  vip_enabled = var.cluster_vip != null && var.cluster_vip != ""

  # Cluster endpoint uses VIP when available, otherwise first control plane IP
  cluster_endpoint = local.vip_enabled ? "https://${var.cluster_vip}:6443" : "https://${local.cp_ips[0]}:6443"

  # Talosctl endpoints include VIP as primary when available
  talos_endpoints = local.vip_enabled ? concat([var.cluster_vip], local.cp_ips) : local.cp_ips
}
