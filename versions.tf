terraform {
  required_version = ">= 1.5.5"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc07"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.10.1"
    }
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.41"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
