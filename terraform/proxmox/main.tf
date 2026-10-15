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

# The installer ISO. Proxmox downloads it. The VMs boot from it.
resource "proxmox_virtual_environment_download_file" "nixos_installer" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.node_name
  url          = var.installer_iso_url
  file_name    = "nixos-minimal-x86_64-linux.iso"
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

  agent {
    enabled = true
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
    file_id   = proxmox_virtual_environment_download_file.nixos_installer.id
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
