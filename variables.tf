variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
}

variable "proxmox_user" {
  description = "Proxmox API user"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox API password"
  type        = string
  sensitive   = true
}

variable "node_cpu_cores" {
  description = "Number of CPU cores per node"
  type        = number
  default     = 2
}

variable "node_memory" {
  description = "Memory in MB per node"
  type        = number
  default     = 4096
}

variable "node_disk_size" {
  description = "Boot disk size per node"
  type        = string
  default     = "40G"
}

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
}

variable "node_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 1
}
