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
  description = "Talos installer image from Image Factory (includes extensions)"
  type        = string
  default     = "factory.talos.dev/installer/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.0"
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
