locals {
  # Subnet prefix length from CIDR (e.g., 24 from "192.168.11.0/24")
  network_prefix_length = tonumber(split("/", var.network_cidr)[1])

  # Extract host number from first IP (last octet for /24 networks)
  cp_first_host     = tonumber(split(".", var.cp_first_ip)[3])
  worker_first_host = tonumber(split(".", var.worker_first_ip)[3])

  # Generate control plane IPs using cidrhost() for reliable IP arithmetic
  cp_ips = [for i in range(var.cp_count) : cidrhost(var.network_cidr, local.cp_first_host + i)]

  # Generate worker IPs using cidrhost()
  worker_ips = [for i in range(var.worker_count) : cidrhost(var.network_cidr, local.worker_first_host + i)]

  # Flatten worker_pools into one node per entry, keyed "<pool>-<n>".
  # Each node carries its pool's settings plus its computed static IP, so the
  # VM resource and the machine config can both key off the same map.
  worker_pool_nodes = merge([
    for pool_name, pool in var.worker_pools : {
      for i in range(pool.count) :
      "${pool_name}-${i + 1}" => {
        pool_name       = pool_name
        index           = i
        name            = "${var.cluster_name}-${pool_name}-${i + 1}"
        ip              = cidrhost(var.network_cidr, tonumber(split(".", pool.first_ip)[3]) + i)
        cpu_cores       = pool.cpu_cores
        memory          = pool.memory
        disk_size       = pool.disk_size
        machine         = pool.machine
        bios            = pool.bios
        iso             = coalesce(pool.iso, var.talos_iso)
        installer_image = coalesce(pool.installer_image, var.talos_installer_image)
        node_labels     = pool.node_labels
        node_taints     = pool.node_taints
        pci_mappings    = pool.pci_mappings
        kernel_modules  = pool.kernel_modules
      }
    }
  ]...)

  # VIP configuration
  vip_enabled = var.cluster_vip != null && var.cluster_vip != ""

  # Cluster endpoint uses VIP when available, otherwise first control plane IP
  cluster_endpoint = local.vip_enabled ? "https://${var.cluster_vip}:6443" : "https://${local.cp_ips[0]}:6443"

  # Talosctl endpoints include VIP as primary when available
  talos_endpoints = local.vip_enabled ? concat([var.cluster_vip], local.cp_ips) : local.cp_ips

  # Kubelet args shared by control plane and worker nodes.
  # rotate-server-certificates makes kubelets serve certs signed by the cluster CA,
  # which metrics-server requires to scrape them over TLS.
  kubelet_extra_args = merge(
    {
      # Required for Proxmox CCM integration
      "cloud-provider" = "external"
    },
    var.metrics_server_enabled ? { "rotate-server-certificates" = "true" } : {}
  )

  # Bootstrap manifests applied by the control plane when metrics-server is enabled
  metrics_server_manifests = var.metrics_server_enabled ? [
    "https://github.com/kubernetes-sigs/metrics-server/releases/download/${var.metrics_server_version}/components.yaml",
  ] : []

  # ---------------------------------------------------------------------------
  # Machine-config patches (Talos v1.14 contract)
  # ---------------------------------------------------------------------------
  #
  # From the v1.14 contract on, the generated config carries most settings as
  # typed documents (KubeletConfig, UnattendedInstallConfig, ResolverConfig,
  # KubeNodeConfig, KubeAPIServerConfig, ...) rather than in the v1alpha1
  # document. Patching the old v1alpha1 fields on top fails validation ("kubelet
  # config is already set in v1alpha1 config"), so every patch here is one
  # document of the matching kind. Talos merges each into the generated
  # document of the same kind (and name).

  # Every node, with the per-node values its machine config needs.
  config_nodes = concat(
    [for i, ip in local.cp_ips : {
      name            = "${var.cluster_name}-cp-${i + 1}"
      ip              = ip
      installer_image = var.talos_installer_image
    }],
    [for i, ip in local.worker_ips : {
      name            = "${var.cluster_name}-worker-${i + 1}"
      ip              = ip
      installer_image = var.talos_installer_image
    }],
    [for n in values(local.worker_pool_nodes) : {
      name            = n.name
      ip              = n.ip
      installer_image = n.installer_image
    }],
  )

  # Documents that differ per node, keyed by node name: installer image,
  # static address and default route on ens18, and hostname.
  node_patches = {
    for n in local.config_nodes : n.name => [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UnattendedInstallConfig"
        # Image Factory installer carrying the node's system extensions.
        # Consumed only at install time and by `talosctl upgrade`.
        installer = { image = n.installer_image }
        # Required under v1.14, and the provider doesn't fill it in. The VM's
        # scsi0 boot disk; under the v1alpha1 layout this was the provider's
        # default machine.install.disk of /dev/sda.
        provisioning = { diskSelector = { match = "disk.dev_path == \"/dev/sda\"" } }
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = "ens18"
        addresses  = [{ address = "${n.ip}/${local.network_prefix_length}" }]
        # No destination: Talos makes this the default route. "0.0.0.0/0"
        # is rejected as a destination.
        routes = [{ gateway = var.gateway }]
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        hostname   = n.name
        auto       = "off"
      }),
    ]
  }

  # Documents every node gets.
  common_patches = concat(
    [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      extraArgs  = local.kubelet_extra_args
    })],
    length(var.nameservers) > 0 ? [yamlencode({
      apiVersion  = "v1alpha1"
      kind        = "ResolverConfig"
      nameservers = [for ns in var.nameservers : { address = ns }]
    })] : [],
  )

  # Documents only the control plane gets: the VIP, API server SANs, the
  # cloud provider and the manifests Talos applies at bootstrap.
  cp_patches = concat(
    [
      # externalCloudProvider has no typed document yet; it stays in v1alpha1.
      yamlencode({
        cluster = {
          externalCloudProvider = {
            enabled = true
            manifests = [
              "https://raw.githubusercontent.com/sergelogvinov/proxmox-cloud-controller-manager/${var.proxmox_ccm_version}/docs/deploy/cloud-controller-manager.yml",
            ]
          }
        }
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "KubeInlineManifestConfig"
        name       = "proxmox-cloud-controller-manager"
        manifest   = <<-EOF
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
      }),
    ],
    [for m in local.kubelet_serving_cert_approver_manifests : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeInlineManifestConfig"
      name       = m.name
      manifest   = m.contents
    })],
    [for i, url in local.metrics_server_manifests : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeExternalManifestConfig"
      name       = i == 0 ? "metrics-server" : "metrics-server-${i}"
      url        = url
    })],
    local.vip_enabled ? [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "Layer2VIPConfig"
        name       = var.cluster_vip
        link       = "ens18"
      }),
      yamlencode({
        apiVersion    = "v1alpha1"
        kind          = "KubeAPIServerConfig"
        certExtraSANs = [var.cluster_vip]
      }),
    ] : [],
  )

  # The approver's upstream manifest limits it to 32Mi, which it outgrows at
  # startup. It doesn't get OOM-killed; the kernel reclaims its binary's pages
  # instead, so it thrashes reading them back from disk, starts too slowly for
  # its liveness probe, and crash-loops. See
  # https://github.com/alex1989hu/kubelet-serving-cert-approver/issues/309
  kubelet_serving_cert_approver_url = "https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/${var.kubelet_serving_cert_approver_version}/deploy/standalone-install.yaml"
  kubelet_serving_cert_approver_resources = {
    requests = { cpu = "10m", memory = "48Mi" }
    limits   = { cpu = "250m", memory = "128Mi" }
  }

  # yamldecode only handles single documents, so patch the manifest one
  # document at a time and re-join it as an inline manifest.
  kubelet_serving_cert_approver_manifests = [
    for r in data.http.kubelet_serving_cert_approver : {
      name = "kubelet-serving-cert-approver"
      contents = join("---\n", [
        for doc in [for d in split("\n---\n", r.response_body) : yamldecode(d) if trimspace(d) != ""] :
        doc.kind != "Deployment" ? yamlencode(doc) : yamlencode(merge(doc, {
          spec = merge(doc.spec, {
            template = merge(doc.spec.template, {
              spec = merge(doc.spec.template.spec, {
                containers = [
                  for c in doc.spec.template.spec.containers :
                  merge(c, { resources = local.kubelet_serving_cert_approver_resources })
                ]
              })
            })
          })
        }))
      ])
    }
  ]
}
