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
#
# Hands-off install: with create_spool and spool_unattend_iso_path set,
# Terraform uploads the answer ISO (spool/build-unattend.sh), attaches it as a
# second CD-ROM and starts the VM. Windows Setup reads autounattend.xml from
# it. See "Create spool" in README.md.

locals {
  spool_iso_file_id = var.windows_iso_file_id != null ? var.windows_iso_file_id : (
    var.create_spool ? proxmox_virtual_environment_download_file.windows_installer[0].id : null
  )

  spool_unattend = var.create_spool && var.spool_unattend_iso_path != null
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

  # With the answer ISO, terraform_data.spool_unattend_cdrom starts the VM
  # after it attaches the ISO. Without it, start at once, as before.
  started = !local.spool_unattend

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

  # spool-setup.ps1 installs the QEMU guest agent at the first logon. Wait
  # 2 minutes for it, not the 15 minute default, so an apply during the
  # install does not stall. A change here needs a stop and start of the VM,
  # not a restart in Windows.
  agent {
    enabled = true
    timeout = "2m"
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
    # Proxmox pins the machine version of a Windows guest at create
    # (pc-q35-11.0+pve2), so Windows does not see new hardware after a
    # Proxmox upgrade. Keep that pin.
    ignore_changes = [
      cdrom,
      boot_order,
      started,
      description,
      tags,
      machine,
    ]
  }
}

# The answer ISO for the hands-off install. Build it first with
# spool/build-unattend.sh. It holds the local Administrator password, so keep
# it on the node only during the install.
resource "proxmox_virtual_environment_file" "spool_unattend_iso" {
  count = local.spool_unattend ? 1 : 0

  content_type = "iso"
  datastore_id = "local"
  node_name    = var.node_name

  source_file {
    path      = var.spool_unattend_iso_path
    file_name = "spool-autounattend.iso"
  }
}

# The second CD-ROM. bpg/proxmox 0.116 allows only one cdrom block on
# proxmox_virtual_environment_vm (bpg/terraform-provider-proxmox#718), and
# the Windows ISO uses it. A disk block with file_id imports the file as a
# hard disk, and Windows Setup does not search hard disks for
# autounattend.xml. So this resource sets ide0 through the Proxmox API with
# spool/attach-unattend.sh. q35 supports ide0 and ide2.
#
# On create: attach ide0, then start the VM and press Enter for the "boot
# from CD" prompt. On destroy (spool_unattend_iso_path back to null): detach
# ide0, before Terraform deletes the ISO from the node.
#
# The script uses PROXMOX_VE_API_TOKEN and PROXMOX_VE_INSECURE from the
# environment, as the provider does.
resource "terraform_data" "spool_unattend_cdrom" {
  count = local.spool_unattend ? 1 : 0

  triggers_replace = [
    proxmox_virtual_environment_vm.spool[0].id,
    proxmox_virtual_environment_file.spool_unattend_iso[0].id,
  ]

  input = {
    script   = "${path.module}/spool/attach-unattend.sh"
    endpoint = var.proxmox_endpoint
    node     = var.node_name
    vmid     = tostring(var.spool.vmid)
    iso      = proxmox_virtual_environment_file.spool_unattend_iso[0].id
  }

  provisioner "local-exec" {
    command = "${self.input.script} attach"
    environment = {
      PVE_ENDPOINT = self.input.endpoint
      PVE_NODE     = self.input.node
      PVE_VMID     = self.input.vmid
      PVE_ISO      = self.input.iso
      PVE_IFACE    = "ide0"
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "${self.input.script} detach"
    environment = {
      PVE_ENDPOINT = self.input.endpoint
      PVE_NODE     = self.input.node
      PVE_VMID     = self.input.vmid
      PVE_IFACE    = "ide0"
    }
  }
}
