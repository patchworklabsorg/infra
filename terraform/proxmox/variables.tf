variable "proxmox_endpoint" {
  description = "Proxmox API URL. The public name is behind Cloudflare. To use the LAN address over the VPN, override this, for example https://<pve01-lan-address>:8006/."
  type        = string
  default     = "https://proxmox.hogwarts.dev/"
}

variable "node_name" {
  description = "Proxmox node that runs the VMs."
  type        = string
  default     = "pve01"
}

variable "datastore_id" {
  description = "Storage for VM disks. local-zfs is full, so use trunk-vms."
  type        = string
  default     = "trunk-vms"
}

variable "bridge" {
  description = "Bridge or SDN vnet of the Patchwork tenant. The vnet pwpriv carries VLAN 90."
  type        = string
  default     = "pwpriv"
}

variable "vlan_id" {
  description = "VLAN tag on the NIC. Keep null when the bridge is the SDN vnet, because the vnet adds the tag."
  type        = number
  default     = null
}

variable "installer_iso_url" {
  description = "URL of the NixOS minimal installer ISO (x86_64). Terraform downloads it to the local storage of the node."
  type        = string
  default     = "https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso"
}

variable "pool_id" {
  description = "Proxmox pool for the VMs. The token ACL is scoped to this pool."
  type        = string
  default     = "patchwork"
}

variable "vms" {
  description = "Patchwork NixOS VMs. The map key is the host name in flake.nix."
  type = map(object({
    vmid      = number
    memory_mb = number
    cores     = number
    disk_gb   = number
    ip        = string
  }))

  default = {
    warp = {
      vmid      = 356
      memory_mb = 6144
      cores     = 4
      disk_gb   = 40
      ip        = "10.100.90.56"
    }
    skein = {
      vmid      = 355
      memory_mb = 4096
      cores     = 2
      disk_gb   = 40
      ip        = "10.100.90.55"
    }
    seam = {
      vmid      = 357
      memory_mb = 2048
      cores     = 2
      disk_gb   = 20
      ip        = "10.100.90.57"
    }
    hem = {
      vmid      = 358
      memory_mb = 2048
      cores     = 2
      disk_gb   = 20
      ip        = "10.100.90.58"
    }
  }
}
