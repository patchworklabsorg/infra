# spool: the Tier 0 jump host (ad/TIERING.md, decision 3). Windows Server
# 2025, joined to patchwork.internal, in T0-Silo. It is not a NixOS host, so
# it is a separate resource: no nixos-anywhere, no NixOS installer ISO.
#
# The VM is created when var.create_spool is true or var.windows_iso_file_id
# is set. With create_spool, Terraform downloads the evaluation ISO (see
# windows_installer in main.tf). A set windows_iso_file_id overrides it.
#
# The disk is SATA and the NIC is e1000e, so the Windows installer needs no
# extra driver ISO. Change to virtio later, after the virtio-win drivers
# are installed, if the speed matters.

locals {
  spool_iso_file_id = var.windows_iso_file_id != null ? var.windows_iso_file_id : (
    var.create_spool ? proxmox_virtual_environment_download_file.windows_installer[0].id : null
  )
}

resource "proxmox_virtual_environment_vm" "spool" {
  count = local.spool_iso_file_id == null ? 0 : 1

  name        = "spool"
  description = "Patchwork Tier 0 jump host spool, ${var.spool.ip}. Windows Server 2025. See ad/TIERING.md. Managed by Terraform."
  tags        = ["windows", "patchwork", "tier0"]
  node_name   = var.node_name
  vm_id       = var.spool.vmid
  pool_id     = var.pool_id

  # UEFI with Secure Boot keys and a TPM 2.0, as Windows Server 2025 expects.
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  on_boot       = true

  operating_system {
    type = "win11"
  }

  cpu {
    type  = "host"
    cores = var.spool.cores
  }

  # No swap on pve01, so do not use ballooning.
  memory {
    dedicated = var.spool.memory_mb
    floating  = 0
  }

  # Turn this on after the QEMU guest agent is installed in Windows.
  # Before that, the provider waits for an agent that does not answer.
  agent {
    enabled = false
  }

  efi_disk {
    datastore_id      = var.datastore_id
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = true
  }

  tpm_state {
    datastore_id = var.datastore_id
    version      = "v2.0"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "sata0"
    size         = var.spool.disk_gb
    file_format  = "raw"
    discard      = "on"
  }

  network_device {
    bridge  = var.bridge
    model   = "e1000e"
    vlan_id = var.vlan_id
  }

  cdrom {
    file_id   = local.spool_iso_file_id
    interface = "ide2"
  }

  boot_order = ["sata0", "ide2"]

  lifecycle {
    prevent_destroy = true

    # Operators detach the ISO and change the boot order after the install.
    ignore_changes = [
      cdrom,
      boot_order,
      started,
      description,
      tags,
      agent,
    ]
  }
}
