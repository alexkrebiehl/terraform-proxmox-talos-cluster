locals {
  cluster_name = "rancher-local-gen3"
  node_ip      = proxmox_vm_qemu.talos_cp.default_ipv4_address
}

# Proxmox VM for Talos control plane
resource "proxmox_vm_qemu" "talos_cp" {
  name        = local.cluster_name
  target_node = "pve"

  agent         = 1
  agent_timeout = 120
  qemu_os       = "l26"
  scsihw        = "virtio-scsi-pci"
  boot          = "order=scsi0;ide2"

  cpu {
    cores = 4
  }
  memory = 8192

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
    size    = "40G"
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

# Generate machine configuration (DHCP, no static IP needed)
data "talos_machine_configuration" "cp" {
  cluster_name     = local.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = "https://${local.node_ip}:6443"
  machine_secrets  = talos_machine_secrets.this.machine_secrets
}

# Client configuration for talosctl
data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = [local.node_ip]
  endpoints            = [local.node_ip]
}

# Apply machine configuration to control plane
resource "talos_machine_configuration_apply" "cp" {
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp.machine_configuration
  node                        = local.node_ip
}

# Bootstrap the cluster
resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.cp]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.node_ip
}

# Get kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.node_ip
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

output "vm_ip_address" {
  value = local.node_ip
}
