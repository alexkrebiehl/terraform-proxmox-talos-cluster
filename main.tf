locals {
  # Static IPs for cluster nodes (outside DHCP range 192.168.11.150-254)
  static_ips = ["192.168.11.61", "192.168.11.62", "192.168.11.63"]
  node_ips   = slice(local.static_ips, 0, var.node_count)
  gateway    = "192.168.11.1"

  # VIP configuration
  vip_enabled = var.cluster_vip != null && var.cluster_vip != ""

  # Cluster endpoint uses VIP when available, otherwise first node IP
  cluster_endpoint = local.vip_enabled ? "https://${var.cluster_vip}:6443" : "https://${local.node_ips[0]}:6443"

  # Talosctl endpoints include VIP as primary when available
  talos_endpoints = local.vip_enabled ? concat([var.cluster_vip], local.node_ips) : local.node_ips
}

# Proxmox VMs for Talos control plane
resource "proxmox_vm_qemu" "talos_cp" {
  count       = var.node_count
  name        = "${var.cluster_name}-cp-${count.index + 1}"
  target_node = "pve"

  agent         = 1
  agent_timeout = 120
  qemu_os       = "l26"
  scsihw        = "virtio-scsi-pci"
  boot          = "order=scsi0;ide2" 

  skip_ipv6 = true

  cpu {
    cores = var.node_cpu_cores
  }
  memory = var.node_memory

  network {
    id       = 0
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = false
  }

  # Boot disk
  disk {
    type    = "disk"
    storage = "vm-data"
    size    = var.node_disk_size
    slot    = "scsi0"
  }

  # Talos ISO
  disk {
    type = "cdrom"
    iso  = "local:iso/talos-v1.12.2-qemu-guest-agent-nocloud-amd64.iso"
    slot = "ide2"
  }

  lifecycle {
    ignore_changes = [boot, disk, startup_shutdown]
  }
}

# Talos machine secrets
resource "talos_machine_secrets" "this" {}

# Generate machine configuration for each control plane node
data "talos_machine_configuration" "cp" {
  count            = var.node_count
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    yamlencode({
      machine = {
        install = {
          # Image Factory installer with qemu-guest-agent extension
          image = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.0"
        }
        network = {
          interfaces = [
            merge(
              {
                interface = "ens18"
                addresses = ["${local.node_ips[count.index]}/24"]
                routes = [
                  {
                    network = "0.0.0.0/0"
                    gateway = local.gateway
                  }
                ]
              },
              local.vip_enabled ? { vip = { ip = var.cluster_vip } } : {}
            )
          ]
          nameservers = ["1.1.1.1", "8.8.8.8"]
        }
      }
      cluster = local.vip_enabled ? {
        apiServer = {
          certSANs = [var.cluster_vip]
        }
      } : {}
    })
  ]
}

# Client configuration for talosctl
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.node_ips
  endpoints            = local.talos_endpoints
}

# Apply machine configuration to each control plane node (connect using DHCP IP)
resource "talos_machine_configuration_apply" "cp" {
  count                       = var.node_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp[count.index].machine_configuration
  # Connect using the DHCP IP from Proxmox, config will set static IP
  node                        = proxmox_vm_qemu.talos_cp[count.index].default_ipv4_address
}

# Wait for nodes to switch to static IPs after config apply
resource "time_sleep" "wait_for_static_ip" {
  depends_on      = [talos_machine_configuration_apply.cp]
  create_duration = "30s"
}

# Bootstrap the cluster (use static IP since config has been applied)
resource "talos_machine_bootstrap" "this" {
  depends_on = [time_sleep.wait_for_static_ip]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.node_ips[0]
}

# Get kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.node_ips[0]
}

resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig.yaml"
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  file_permission = "0600"
}

resource "local_file" "talosconfig" {
  filename        = "${path.module}/talosconfig.yaml"
  content         = data.talos_client_configuration.this.talos_config
  file_permission = "0600"
}

output "kubeconfig_yaml" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}

output "vm_ip_addresses" {
  value = local.node_ips
}

output "cluster_vip" {
  description = "Virtual IP for control plane (empty if not configured)"
  value       = var.cluster_vip
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint URL"
  value       = local.cluster_endpoint
}
