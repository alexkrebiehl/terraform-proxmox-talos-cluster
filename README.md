# terraform-proxmox-talos-cluster

Terraform module that provisions a Talos Linux Kubernetes cluster on Proxmox VE.

## Overview

The module owns the full path from an empty Proxmox node to a working cluster:

- **Network** — a dedicated Unifi VLAN and virtual network with a DHCP range for node bring-up.
- **VMs** — Proxmox QEMU VMs for control plane and worker nodes, booted from a Talos ISO and
  installed with an Image Factory image that includes the qemu-guest-agent extension.
- **Talos** — machine secrets, per-node machine configuration (static IPs, hostnames, optional
  control plane VIP), bootstrap, and kubeconfig/talosconfig outputs.
- **Proxmox Cloud Controller Manager** — deployed as a bootstrap manifest with its credentials
  delivered as an inline manifest.
- **Metrics server** — optional (on by default), see [Metrics server](#metrics-server).

Nodes get DHCP addresses first, then the applied machine configuration moves them to the static IPs
derived from `cp_first_ip` / `worker_first_ip`.

## Usage

```hcl
module "talos_cluster" {
  source = "github.com/alexkrebiehl/terraform-proxmox-talos-cluster?ref=v1.3.0"

  cluster_name = "talos-cluster"
  disk_storage = "zpool"

  # Network
  vlan_id         = 206
  network_cidr    = "172.20.6.1/24"
  gateway         = "172.20.6.1"
  cluster_vip     = "172.20.6.5"
  cp_first_ip     = "172.20.6.10"
  worker_first_ip = "172.20.6.20"

  # Sizing
  cp_count     = 3
  worker_count = 1

  # Proxmox Cloud Controller Manager
  proxmox_ccm_url          = "https://pve.example.com:8006/api2/json"
  proxmox_ccm_token_id     = "root@pam!proxmox-ccm"
  proxmox_ccm_token_secret = var.proxmox_ccm_token_secret
  proxmox_ccm_region       = "talos-cluster"
}
```

The module expects the `proxmox`, `unifi`, `talos`, and `time` providers to be configured by the
calling root module.

## Inputs

### Cluster

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `cluster_name` | `string` | _required_ | Name of the Talos cluster |
| `cluster_vip` | `string` | `""` | Virtual IP for the control plane endpoint (empty for single-node) |
| `cp_count` | `number` | `1` | Number of control plane nodes (1-3) |
| `worker_count` | `number` | `0` | Number of worker nodes (0-5) |

### Proxmox

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `proxmox_node` | `string` | `"pve"` | Proxmox node to deploy VMs on |
| `disk_storage` | `string` | `"vm-data"` | Proxmox storage pool for VM disks |
| `talos_iso` | `string` | `local:iso/talos-v1.12.2-…-amd64.iso` | Proxmox ISO path for the Talos boot image |
| `talos_installer_image` | `string` | Image Factory image w/ qemu-guest-agent | Talos installer image |

### Node sizing

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `cp_cpu_cores` | `number` | `2` | CPU cores per control plane node |
| `cp_memory` | `number` | `4096` | Memory in MB per control plane node |
| `cp_disk_size` | `string` | `"40G"` | Boot disk size per control plane node |
| `worker_cpu_cores` | `number` | `2` | CPU cores per worker node |
| `worker_memory` | `number` | `4096` | Memory in MB per worker node |
| `worker_disk_size` | `string` | `"40G"` | Boot disk size per worker node |

### Network

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `vlan_id` | `number` | _required_ | VLAN ID for the cluster network (1-4094) |
| `network_cidr` | `string` | _required_ | Network CIDR for cluster nodes |
| `gateway` | `string` | _required_ | Default gateway IP address |
| `cp_first_ip` | `string` | _required_ | First static IP for control plane nodes (auto-increments) |
| `worker_first_ip` | `string` | _required_ | First static IP for worker nodes (auto-increments) |
| `nameservers` | `list(string)` | `["172.21.21.21"]` | DNS nameservers for cluster nodes |
| `network_dhcp_start` | `number` | `200` | DHCP range start (host number within the subnet) |
| `network_dhcp_stop` | `number` | `250` | DHCP range stop (host number within the subnet) |

### Proxmox Cloud Controller Manager

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `proxmox_ccm_url` | `string` | _required_ | Proxmox API URL for the CCM |
| `proxmox_ccm_token_id` | `string` | _required_ | Proxmox API token ID for the CCM |
| `proxmox_ccm_token_secret` | `string` | _required_ | Proxmox API token secret for the CCM (sensitive) |
| `proxmox_ccm_region` | `string` | _required_ | Region identifier for the CCM |
| `proxmox_ccm_insecure` | `bool` | `false` | Skip TLS verification for the Proxmox API connection |
| `proxmox_ccm_version` | `string` | `"v0.13.0"` | Version of the CCM to deploy |

### Metrics server

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `metrics_server_enabled` | `bool` | `true` | Deploy metrics-server and the kubelet serving certificate approver it requires |
| `metrics_server_version` | `string` | `"v0.9.0"` | Version of metrics-server to deploy |
| `kubelet_serving_cert_approver_version` | `string` | `"v0.11.0"` | Version of the kubelet serving certificate approver to deploy |

## Outputs

| Name | Description |
| --- | --- |
| `kubeconfig_yaml` | Kubeconfig for cluster access (sensitive) |
| `talosconfig_yaml` | Talosconfig for `talosctl` access (sensitive) |
| `cp_ip_addresses` | Static IP addresses of control plane nodes |
| `worker_ip_addresses` | Static IP addresses of worker nodes |
| `cluster_vip` | Virtual IP for the control plane (empty if not configured) |
| `cluster_endpoint` | Kubernetes API endpoint URL |

## Metrics server

Enabled by default (`metrics_server_enabled = true`). Two things are needed on Talos, and the module
does both:

1. Sets `rotate-server-certificates=true` in the kubelet `extraArgs` of **both** control plane and
   worker nodes, so kubelets serve certificates signed by the cluster CA. Without this they serve
   self-signed certificates that metrics-server refuses to scrape.
2. Adds two `cluster.extraManifests` entries — the
   [kubelet-serving-cert-approver](https://github.com/alex1989hu/kubelet-serving-cert-approver),
   which auto-approves the kubelet serving CSRs that rotation creates, and
   [metrics-server](https://github.com/kubernetes-sigs/metrics-server) itself.

Versions are pinned through `metrics_server_version` and `kubelet_serving_cert_approver_version`
rather than tracking `latest`, so upgrades are an explicit change.

Both components are applied by Talos's manifest controller on the control plane, which reconciles
continuously — enabling this on an already-running cluster works without re-bootstrapping.

Verify after applying:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io   # AVAILABLE=True
kubectl top nodes
```

### Disabling does not uninstall

Talos only ever *applies* `extraManifests` — it never prunes them. Setting
`metrics_server_enabled = false` stops Talos from re-applying the manifests, but everything already
created stays in the cluster and must be removed by hand:

```bash
kubectl delete -f https://github.com/kubernetes-sigs/metrics-server/releases/download/<version>/components.yaml
kubectl delete -f https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/<version>/deploy/standalone-install.yaml
```

Use the versions that were actually deployed, not the current defaults, or the delete will miss
objects. Note that kubelet certificate rotation *is* reverted by the config change, so a
metrics-server left running after disabling will fail its scrapes.

## Requirements

| Name | Version |
| --- | --- |
| terraform | >= 1.5.5 |
| Telmate/proxmox | 3.0.2-rc07 |
| siderolabs/talos | 0.10.1 |
| ubiquiti-community/unifi | ~> 0.41 |
| hashicorp/time | ~> 0.9 |
