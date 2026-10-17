# For later only. No VM exists yet. If a VM exists in the future, uncomment its
# import block before the plan. The ID format is <node>/<vmid>.
#
# import {
#   to = proxmox_virtual_environment_vm.nixos["warp"]
#   id = "pve01/356"
# }
# import {
#   to = proxmox_virtual_environment_vm.nixos["skein"]
#   id = "pve01/355"
# }
# import {
#   to = proxmox_virtual_environment_vm.nixos["seam"]
#   id = "pve01/357"
# }
# import {
#   to = proxmox_virtual_environment_vm.nixos["hem"]
#   id = "pve01/358"
# }

# The installer ISO. `nix build .#installer-iso -o result-installer` builds it
# (root takes the admin SSH keys). Terraform uploads it to the node. The VMs
# boot from it.
resource "proxmox_virtual_environment_file" "installer_iso" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.node_name

  source_file {
    path      = var.installer_iso_path
    file_name = "patchwork-nixos-installer.iso"
  }
}

# The stock ISO download is gone. This block removes it from the state and
# keeps the file on the node, because the CD-ROM of existing VMs may still
# point to it. Delete the file by hand when no VM uses it.
removed {
  from = proxmox_virtual_environment_download_file.nixos_installer

  lifecycle {
    destroy = false
  }
}

# The Windows Server 2025 evaluation ISO for spool. Proxmox downloads it.
# It is created only when var.create_spool is true.
resource "proxmox_virtual_environment_download_file" "windows_installer" {
  count = var.create_spool ? 1 : 0

  content_type   = "iso"
  datastore_id   = "local"
  node_name      = var.node_name
  url            = var.windows_iso_url
  file_name      = "windows-server-2025-eval.iso"
  overwrite      = false
  verify         = true
  upload_timeout = 7200
}

# Shape matches hosts/proxmox-vm.nix: SeaBIOS, one virtio-scsi disk at
# /dev/sda, cpu host, QEMU guest agent on.
resource "proxmox_virtual_environment_vm" "nixos" {
  for_each = var.vms

  name        = each.key
  description = "Patchwork NixOS host ${each.key}, ${each.value.ip}. Managed by Terraform."
  tags        = ["nixos", "patchwork"]
  node_name   = var.node_name
  vm_id       = each.value.vmid
  pool_id     = var.pool_id

  bios          = "seabios"
  machine       = "pc"
  scsi_hardware = "virtio-scsi-single"
  on_boot       = true

  operating_system {
    type = "l26"
  }

  cpu {
    type  = "host"
    cores = each.value.cores
  }

  # No swap on pve01, so do not use ballooning.
  memory {
    dedicated = each.value.memory_mb
    floating  = 0
  }

  # Wait 2 minutes for the guest agent, not the 15 minute default. A VM
  # without an agent (before the install) then does not stall an apply.
  agent {
    enabled = true
    timeout = "2m"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_gb
    file_format  = "raw"
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge  = var.bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  # Boot from the installer ISO. nixos-anywhere installs to the disk.
  cdrom {
    file_id   = proxmox_virtual_environment_file.installer_iso.id
    interface = "ide2"
  }

  boot_order = ["scsi0", "ide2"]

  lifecycle {
    prevent_destroy = true

    # Operators detach the ISO and change the boot order after the install.
    ignore_changes = [
      cdrom,
      boot_order,
      started,
      description,
      tags,
    ]
  }
}
