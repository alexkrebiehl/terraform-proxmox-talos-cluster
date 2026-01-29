# =============================================================================
# Unifi Network Configuration
# =============================================================================

# Create dedicated VLAN network for Talos cluster
resource "unifi_virtual_network" "talos" {
  name         = "${var.cluster_name}-network"
  subnet       = var.network_cidr
  vlan         = var.vlan_id
  enabled      = true
  vlan_enabled = true

  dhcp_server = {
    enabled     = true
    start       = cidrhost(var.network_cidr, var.network_dhcp_start)
    stop        = cidrhost(var.network_cidr, var.network_dhcp_stop)
    dns_servers = var.nameservers
  }
}

# =============================================================================
# Proxmox VMs for Talos Control Plane
# =============================================================================

# Proxmox VMs for Talos control plane
resource "proxmox_vm_qemu" "talos_cp" {
  count       = var.cp_count
  name        = "${var.cluster_name}-cp-${count.index + 1}"
  target_node = var.proxmox_node

  agent         = 1
  agent_timeout = 120
  qemu_os       = "l26"
  scsihw        = "virtio-scsi-pci"
  boot          = "order=scsi0;ide2"

  skip_ipv6 = true

  cpu {
    cores = var.cp_cpu_cores
  }
  memory = var.cp_memory

  network {
    id       = 0
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = false
    tag      = unifi_virtual_network.talos.vlan
  }

  # Boot disk
  disk {
    type    = "disk"
    storage = var.disk_storage
    size    = var.cp_disk_size
    slot    = "scsi0"
  }

  # Talos ISO
  disk {
    type = "cdrom"
    iso  = var.talos_iso
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
  count            = var.cp_count
  cluster_name     = var.cluster_name
  machine_type     = "controlplane"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    yamlencode({
      machine = {
        install = {
          # Image Factory installer with qemu-guest-agent extension
          image = var.talos_installer_image
        }
        network = {
          interfaces = [
            merge(
              {
                interface = "ens18"
                addresses = ["${local.cp_ips[count.index]}/${local.network_prefix_length}"]
                routes = [
                  {
                    network = "0.0.0.0/0"
                    gateway = var.gateway
                  }
                ]
              },
              local.vip_enabled ? { vip = { ip = var.cluster_vip } } : {}
            )
          ]
          nameservers = var.nameservers
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
  nodes                = local.cp_ips
  endpoints            = local.talos_endpoints
}

# Apply machine configuration to each control plane node (connect using DHCP IP)
resource "talos_machine_configuration_apply" "cp" {
  count                       = var.cp_count
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp[count.index].machine_configuration
  # Connect using the DHCP IP from Proxmox, config will set static IP
  node = proxmox_vm_qemu.talos_cp[count.index].default_ipv4_address
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
  node                 = local.cp_ips[0]
}

# Get kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cp_ips[0]
}

# =============================================================================
# Worker Nodes
# =============================================================================

# Proxmox VMs for Talos workers
resource "proxmox_vm_qemu" "talos_worker" {
  count       = var.worker_count
  name        = "${var.cluster_name}-worker-${count.index + 1}"
  target_node = var.proxmox_node

  agent         = 1
  agent_timeout = 120
  qemu_os       = "l26"
  scsihw        = "virtio-scsi-pci"
  boot          = "order=scsi0;ide2"

  skip_ipv6 = true

  cpu {
    cores = var.worker_cpu_cores
  }
  memory = var.worker_memory

  network {
    id       = 0
    bridge   = "vmbr0"
    model    = "virtio"
    firewall = false
    tag      = unifi_virtual_network.talos.vlan
  }

  # Boot disk
  disk {
    type    = "disk"
    storage = var.disk_storage
    size    = var.worker_disk_size
    slot    = "scsi0"
  }

  # Talos ISO
  disk {
    type = "cdrom"
    iso  = var.talos_iso
    slot = "ide2"
  }

  lifecycle {
    ignore_changes = [boot, disk, startup_shutdown]
  }
}

# Generate machine configuration for each worker node
data "talos_machine_configuration" "worker" {
  count            = var.worker_count
  cluster_name     = var.cluster_name
  machine_type     = "worker"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    yamlencode({
      machine = {
        install = {
          # Image Factory installer with qemu-guest-agent extension
          image = var.talos_installer_image
        }
        network = {
          interfaces = [
            {
              interface = "ens18"
              addresses = ["${local.worker_ips[count.index]}/${local.network_prefix_length}"]
              routes = [
                {
                  network = "0.0.0.0/0"
                  gateway = var.gateway
                }
              ]
            }
          ]
          nameservers = var.nameservers
        }
      }
    })
  ]
}

# Apply machine configuration to each worker node (after cluster bootstrap)
resource "talos_machine_configuration_apply" "worker" {
  count      = var.worker_count
  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  # Connect using the DHCP IP from Proxmox, config will set static IP
  node = proxmox_vm_qemu.talos_worker[count.index].default_ipv4_address
}
