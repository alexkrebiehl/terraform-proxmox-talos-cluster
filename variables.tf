# =============================================================================
# Proxmox Configuration
# =============================================================================

variable "proxmox_node" {
  description = "Proxmox node to deploy VMs on"
  type        = string
  default     = "pve"
}

variable "disk_storage" {
  description = "Proxmox storage pool for VM disks"
  type        = string
  default     = "vm-data"
}

variable "start_at_node_boot" {
  description = "Start cluster VMs automatically when the Proxmox node boots"
  type        = bool
  default     = true
}

# =============================================================================
# Proxmox Cloud Controller Manager Configuration
# =============================================================================

variable "proxmox_ccm_url" {
  description = "Proxmox API URL for Cloud Controller Manager (e.g., https://cluster-api-1.example.com:8006/api2/json)"
  type        = string
}

variable "proxmox_ccm_insecure" {
  description = "Skip TLS verification for Proxmox API connection"
  type        = bool
  default     = false
}

variable "proxmox_ccm_token_id" {
  description = "Proxmox API token ID for Cloud Controller Manager (e.g., kubernetes@pve!ccm)"
  type        = string
}

variable "proxmox_ccm_token_secret" {
  description = "Proxmox API token secret for Cloud Controller Manager"
  type        = string
  sensitive   = true
}

variable "proxmox_ccm_region" {
  description = "Region identifier for Proxmox Cloud Controller Manager"
  type        = string
}

variable "proxmox_ccm_version" {
  description = "Version of the Proxmox Cloud Controller Manager to deploy"
  type        = string
  default     = "v0.13.0"
}

# =============================================================================
# Talos Configuration
# =============================================================================

variable "talos_iso" {
  description = "Proxmox ISO path for Talos boot image"
  type        = string
  default     = "local:iso/talos-v1.12.2-qemu-guest-agent-nocloud-amd64.iso"
}

variable "talos_installer_image" {
  description = "Talos installer image from Image Factory (includes extensions). Keep the version in sync with talos_iso."
  type        = string
  default     = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.2"
}

# =============================================================================
# Worker Pools
# =============================================================================

# Additional worker pools, on top of the count-based worker_count pool above.
# Each pool is independent: its own sizing, IP range, Talos image, node labels
# and taints, and optional Proxmox PCI passthrough.
#
# The legacy worker_count pool is intentionally left alone. Migrating it from
# count to for_each would rewrite state for a node that carries dynamically
# attached CSI volumes Terraform does not manage, for no benefit today.
variable "worker_pools" {
  description = "Additional worker pools, keyed by pool name."
  type = map(object({
    count     = number
    cpu_cores = number
    memory    = number
    disk_size = string

    # First IP of the pool's contiguous range. Must not overlap the control
    # plane range, the worker_count range, MetalLB, or the DHCP range.
    first_ip = string

    # Override the cluster-wide Talos image for this pool only. Use when a pool
    # needs system extensions the rest of the cluster does not (e.g. amdgpu).
    installer_image = optional(string)
    iso             = optional(string)

    # PCI passthrough wants q35 + OVMF. Defaults match the rest of the cluster
    # so a plain pool behaves exactly like the existing workers.
    machine = optional(string, "")
    bios    = optional(string, "seabios")

    node_labels = optional(map(string), {})

    # Talos expects "value:Effect", e.g. { gpu = "amd:NoSchedule" }.
    #
    # WARNING: this does not work on worker nodes in a default cluster. The
    # NodeRestriction admission plugin forbids a node from tainting itself
    # ("node X is forbidden: node is not allowed to modify taints"), and that
    # error aborts Talos's NodeApplyController mid-reconcile, so it crash-loops
    # and never applies node_labels either -- you lose both, silently.
    # Prefer node_labels here and apply taints from the control plane with
    # `kubectl taint`.
    node_taints = optional(map(string), {})

    # Names of Proxmox cluster PCI resource mappings to attach, in order.
    # Mappings are referenced by name rather than raw BDF so the config
    # survives PCI renumbering on the host.
    pci_mappings = optional(list(string), [])

    # Kernel modules Talos should load on these nodes, e.g. ["amdgpu"].
    kernel_modules = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.worker_pools : length(v.pci_mappings) <= 16])
    error_message = "A worker pool can attach at most 16 PCI mappings."
  }

  validation {
    condition     = alltrue([for k, v in var.worker_pools : v.count <= 1 if length(v.pci_mappings) > 0])
    error_message = "A pool with PCI passthrough must have count = 1: a passed-through device cannot be shared between VMs."
  }

  validation {
    condition     = alltrue([for k, v in var.worker_pools : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", v.first_ip))])
    error_message = "Each worker pool's first_ip must be a valid IPv4 address."
  }
}

variable "cp_cpu_cores" {
  description = "Number of CPU cores per control plane node"
  type        = number
  default     = 2
}

variable "cp_memory" {
  description = "Memory in MB per control plane node"
  type        = number
  default     = 4096
}

variable "cp_disk_size" {
  description = "Boot disk size per control plane node"
  type        = string
  default     = "40G"
}

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
}

variable "cp_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.cp_count >= 1 && var.cp_count <= 3
    error_message = "cp_count must be between 1 and 3 (available static IPs)"
  }
}

variable "cluster_vip" {
  description = "Virtual IP for control plane endpoint (optional, empty for single-node)"
  type        = string
  default     = ""

  validation {
    condition     = var.cluster_vip == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.cluster_vip))
    error_message = "cluster_vip must be a valid IPv4 address or empty string"
  }
}

# Worker node variables
variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 0

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 5
    error_message = "worker_count must be between 0 and 5 (available static IPs)"
  }
}

variable "worker_cpu_cores" {
  description = "Number of CPU cores per worker node"
  type        = number
  default     = 2
}

variable "worker_memory" {
  description = "Memory in MB per worker node"
  type        = number
  default     = 4096
}

variable "worker_disk_size" {
  description = "Boot disk size per worker node"
  type        = string
  default     = "40G"
}

# Network configuration
variable "vlan_id" {
  description = "VLAN ID for the Talos cluster network"
  type        = number

  validation {
    condition     = var.vlan_id >= 1 && var.vlan_id <= 4094
    error_message = "vlan_id must be between 1 and 4094"
  }
}

variable "network_cidr" {
  description = "Network CIDR for cluster nodes (e.g., 172.20.6.0/24)"
  type        = string

  validation {
    condition     = can(cidrhost(var.network_cidr, 0))
    error_message = "network_cidr must be a valid CIDR block"
  }
}

variable "gateway" {
  description = "Default gateway IP address (typically .1 of the network)"
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.gateway))
    error_message = "gateway must be a valid IPv4 address"
  }
}

variable "cp_first_ip" {
  description = "First static IP for control plane nodes (subsequent IPs auto-increment)"
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.cp_first_ip))
    error_message = "cp_first_ip must be a valid IPv4 address"
  }
}

variable "worker_first_ip" {
  description = "First static IP for worker nodes (subsequent IPs auto-increment)"
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.worker_first_ip))
    error_message = "worker_first_ip must be a valid IPv4 address"
  }
}

variable "nameservers" {
  description = "DNS nameservers for cluster nodes"
  type        = list(string)
  default     = ["172.21.21.21"]
}

variable "network_dhcp_start" {
  description = "DHCP range start (host number within the subnet)"
  type        = number
  default     = 200
}

variable "network_dhcp_stop" {
  description = "DHCP range stop (host number within the subnet)"
  type        = number
  default     = 250
}

# =============================================================================
# Metrics Server Configuration
# =============================================================================

variable "metrics_server_enabled" {
  description = "Deploy metrics-server and the kubelet serving certificate approver it requires"
  type        = bool
  default     = true
}

variable "metrics_server_version" {
  description = "Version of metrics-server to deploy"
  type        = string
  default     = "v0.9.0"
}

variable "kubelet_serving_cert_approver_version" {
  description = "Version of the kubelet serving certificate approver to deploy"
  type        = string
  default     = "v0.11.0"
}
