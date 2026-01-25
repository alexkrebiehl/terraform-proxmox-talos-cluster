locals {
  node_ips         = [for vm in proxmox_vm_qemu.talos_cp : vm.default_ipv4_address]
  cluster_endpoint = "https://${local.node_ips[0]}:6443"
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
    ignore_changes = [boot]
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
      }
    })
  ]
}

# Client configuration for talosctl
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = local.node_ips
  endpoints            = local.node_ips
}

# Apply machine configuration to each control plane node
resource "talos_machine_configuration_apply" "cp" {
  count                       = var.node_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp[count.index].machine_configuration
  node                        = local.node_ips[count.index]
}

# Bootstrap the cluster (only from first node, after all nodes configured)
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.cp]

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
