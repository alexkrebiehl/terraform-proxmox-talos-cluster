# =============================================================================
# Network
# =============================================================================
#
# The cluster VLAN is NOT managed here: it must already exist in UniFi. See
# "Networking prerequisites" in README.md for what it needs and why.

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
    tag      = var.vlan_id
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

# Upstream approver manifest, fetched so its resources can be patched before
# it is inlined (see local.kubelet_serving_cert_approver_manifests)
data "http" "kubelet_serving_cert_approver" {
  count = var.metrics_server_enabled ? 1 : 0
  url   = local.kubelet_serving_cert_approver_url

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && strcontains(self.response_body, "kind: Deployment")
      error_message = "Could not fetch the kubelet-serving-cert-approver manifest from ${local.kubelet_serving_cert_approver_url} (HTTP ${self.status_code}), or it no longer contains a Deployment to patch."
    }
  }
}

# Generate machine configuration for each control plane node
data "talos_machine_configuration" "cp" {
  count              = var.cp_count
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches = concat(
    local.node_patches["${var.cluster_name}-cp-${count.index + 1}"],
    local.common_patches,
    local.cp_patches,
  )
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
  apply_mode                  = var.apply_mode
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
    tag      = var.vlan_id
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
  count              = var.worker_count
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches = concat(
    local.node_patches["${var.cluster_name}-worker-${count.index + 1}"],
    local.common_patches,
  )
}

# Apply machine configuration to each worker node (after cluster bootstrap)
resource "talos_machine_configuration_apply" "worker" {
  count      = var.worker_count
  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[count.index].machine_configuration
  apply_mode                  = var.apply_mode
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
    tag      = var.vlan_id
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
  for_each           = local.worker_pool_nodes
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches = concat(
    local.node_patches[each.value.name],
    local.common_patches,
    length(each.value.node_labels) > 0 || length(each.value.node_taints) > 0 ? [yamlencode(merge(
      { apiVersion = "v1alpha1", kind = "KubeNodeConfig" },
      length(each.value.node_labels) > 0 ? { labels = each.value.node_labels } : {},
      length(each.value.node_taints) > 0 ? { taints = each.value.node_taints } : {},
    ))] : [],
    [for m in each.value.kernel_modules : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KernelModuleConfig"
      name       = m
    })],
  )
}

# Apply machine configuration to each worker pool node (after cluster bootstrap)
resource "talos_machine_configuration_apply" "worker_pool" {
  for_each   = local.worker_pool_nodes
  depends_on = [talos_machine_bootstrap.this]

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker_pool[each.key].machine_configuration
  apply_mode                  = var.apply_mode
  # Connect using the DHCP IP from Proxmox, falling back to the static IP
  # (see the control plane equivalent above)
  node = coalesce(proxmox_vm_qemu.talos_worker_pool[each.key].default_ipv4_address, each.value.ip)
}
