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

variable "installer_iso_path" {
  description = "Local path of the Patchwork installer ISO. Build it with: nix build .#installer-iso -o result-installer. Terraform uploads it to the local storage of the node."
  type        = string
  default     = "../../result-installer/iso/patchwork-nixos-installer.iso"
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
    batting = {
      vmid      = 360
      memory_mb = 4096
      cores     = 2
      disk_gb   = 20
      ip        = "10.100.90.60"
    }
    weft = {
      vmid      = 361
      memory_mb = 4096
      cores     = 2
      disk_gb   = 40
      ip        = "10.100.90.61"
    }
  }
}

variable "create_spool" {
  description = "Create the spool VM. When true, Terraform also downloads the Windows Server 2025 evaluation ISO, unless windows_iso_file_id is set."
  type        = bool
  default     = false
}

variable "windows_iso_url" {
  description = "URL of the Windows Server 2025 evaluation ISO (English, x64). The Microsoft fwlink redirects to the file SERVER_EVAL_x64FRE_en-us.iso, about 5.6 GiB."
  type        = string
  default     = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us"
}

variable "windows_iso_file_id" {
  description = "Proxmox file ID of an existing Windows Server 2025 ISO, for example local:iso/WindowsServer2025.iso. It overrides the downloaded ISO. While it is null and create_spool is false, the spool VM is not created."
  type        = string
  default     = null
}

variable "spool" {
  description = "The Tier 0 jump host spool (Windows Server 2025), VMID 359 at 10.100.90.59. The memory matches the live VM (8 GiB)."
  type = object({
    vmid      = number
    memory_mb = number
    cores     = number
    disk_gb   = number
    ip        = string
  })

  default = {
    vmid      = 359
    memory_mb = 8192
    cores     = 2
    disk_gb   = 60
    ip        = "10.100.90.59"
  }
}

variable "spool_agent_installed" {
  description = "The QEMU guest agent runs in Windows on spool, so Terraform turns on the agent device. It is true for the live VM. For a new spool, set it to false until spool-setup.ps1 or a person installs the agent."
  type        = bool
  default     = true
}

variable "spool_unattend_iso_path" {
  description = "Local path of the spool answer ISO. Build it with spool/build-unattend.sh. When it is set and create_spool is true, Terraform uploads the ISO, attaches it to spool as a second CD-ROM (ide0) and starts the install. Keep it null after the install: Terraform then detaches the ISO and deletes it from the node."
  type        = string
  default     = null
}
