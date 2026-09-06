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

  agent              = 1
  agent_timeout      = 120
  qemu_os            = "l26"
  scsihw             = "virtio-scsi-pci"
  boot               = "order=scsi0;ide2"
  start_at_node_boot = var.start_at_node_boot

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
        kubelet = {
          extraArgs = local.kubelet_extra_args
        }
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
      cluster = {
        inlineManifests = [
          {
            name : "proxmox-cloud-controller-manager",
            contents : <<EOF
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: proxmox-cloud-controller-manager
  namespace: kube-system
stringData:
  config.yaml: |
    clusters:
      - url: ${var.proxmox_ccm_url}
        insecure: ${var.proxmox_ccm_insecure}
        token_id: "${var.proxmox_ccm_token_id}"
        token_secret: "${var.proxmox_ccm_token_secret}"
        region: ${var.proxmox_ccm_region}
EOF
          },
        ]
        externalCloudProvider = {
          enabled = true
          manifests = [
            "https://raw.githubusercontent.com/sergelogvinov/proxmox-cloud-controller-manager/${var.proxmox_ccm_version}/docs/deploy/cloud-controller-manager.yml",
          ]
        }
        extraManifests = local.metrics_server_manifests
        apiServer = local.vip_enabled ? {
          certSANs = [var.cluster_vip]
        } : null
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = "${var.cluster_name}-cp-${count.index + 1}"
      auto       = "off"
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
  # Connect using the DHCP IP reported by the qemu-guest-agent during initial
  # bring-up, falling back to the static IP the config assigns. The fallback
  # matters once the node is running: if the guest agent stops reporting,
  # Proxmox returns an empty address and the node is already on its static IP.
  node = coalesce(proxmox_vm_qemu.talos_cp[count.index].default_ipv4_address, local.cp_ips[count.index])
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

  agent              = 1
  agent_timeout      = 120
  qemu_os            = "l26"
  scsihw             = "virtio-scsi-pci"
  boot               = "order=scsi0;ide2"
  start_at_node_boot = var.start_at_node_boot

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
        kubelet = {
          extraArgs = local.kubelet_extra_args
        }
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
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = "${var.cluster_name}-worker-${count.index + 1}"
      auto       = "off"
    })
  ]
}

# Apply machine configuration to each worker node (after cluster bootstrap)
resource "talos_machine_configuration_apply" "worker" {
  count      = var.worker_count
  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  # Connect using the DHCP IP from Proxmox, falling back to the static IP
  # (see the control plane equivalent above)
  node = coalesce(proxmox_vm_qemu.talos_worker[count.index].default_ipv4_address, local.worker_ips[count.index])
}

# =============================================================================
# Worker Pools
# =============================================================================
#
# Additional worker pools defined by var.worker_pools. These are separate from
# the count-based talos_worker resource above so that adding a pool never
# rewrites state for the existing workers.
#
# A pool may pin its own Talos image, so a pool that needs system extensions
# (e.g. amdgpu for a passed-through GPU) does not force those extensions onto
# the rest of the cluster.

resource "proxmox_vm_qemu" "talos_worker_pool" {
  for_each    = local.worker_pool_nodes
  name        = each.value.name
  target_node = var.proxmox_node

  agent              = 1
  agent_timeout      = 120
  qemu_os            = "l26"
  scsihw             = "virtio-scsi-pci"
  boot               = "order=scsi0;ide2"
  start_at_node_boot = var.start_at_node_boot

  skip_ipv6 = true

  # PCI passthrough needs q35 + OVMF. Pools without passthrough leave these at
  # the same defaults as the existing workers.
  machine = each.value.machine
  bios    = each.value.bios

  cpu {
    cores = each.value.cpu_cores
  }
  memory = each.value.memory

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
    size    = each.value.disk_size
    slot    = "scsi0"
  }

  # Talos ISO
  disk {
    type = "cdrom"
    iso  = each.value.iso
    slot = "ide2"
  }

  # UEFI variable store, required when bios = "ovmf".
  dynamic "efidisk" {
    for_each = each.value.bios == "ovmf" ? [1] : []
    content {
      storage = var.disk_storage
      efitype = "4m"
    }
  }

  # Passed-through PCI devices, addressed by Proxmox resource mapping name.
  # primary_gpu stays false: these are headless compute devices, not consoles.
  dynamic "pci" {
    for_each = each.value.pci_mappings
    content {
      id          = pci.key
      mapping_id  = pci.value
      pcie        = true
      rombar      = true
      primary_gpu = false
    }
  }

  lifecycle {
    ignore_changes = [boot, disk, startup_shutdown]
  }
}

# Generate machine configuration for each worker pool node
data "talos_machine_configuration" "worker_pool" {
  for_each         = local.worker_pool_nodes
  cluster_name     = var.cluster_name
  machine_type     = "worker"
  cluster_endpoint = local.cluster_endpoint
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  config_patches = [
    yamlencode({
      machine = merge(
        {
          kubelet = {
            extraArgs = local.kubelet_extra_args
          }
          install = {
            # Pool-specific Image Factory installer, falling back to the
            # cluster-wide image when the pool does not override it.
            image = each.value.installer_image
          }
          network = {
            interfaces = [
              {
                interface = "ens18"
                addresses = ["${each.value.ip}/${local.network_prefix_length}"]
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
        },
        length(each.value.node_labels) > 0 ? { nodeLabels = each.value.node_labels } : {},
        length(each.value.node_taints) > 0 ? { nodeTaints = each.value.node_taints } : {},
        length(each.value.kernel_modules) > 0 ? {
          kernel = { modules = [for m in each.value.kernel_modules : { name = m }] }
        } : {},
      )
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.value.name
      auto       = "off"
    })
  ]
}

# Apply machine configuration to each worker pool node (after cluster bootstrap)
resource "talos_machine_configuration_apply" "worker_pool" {
  for_each   = local.worker_pool_nodes
  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker_pool[each.key].machine_configuration
  # Connect using the DHCP IP from Proxmox, falling back to the static IP
  # (see the control plane equivalent above)
  node = coalesce(proxmox_vm_qemu.talos_worker_pool[each.key].default_ipv4_address, each.value.ip)
}
