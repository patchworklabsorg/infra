output "vms" {
  description = "VMID and address of each managed VM."
  value = {
    for name, vm in proxmox_virtual_environment_vm.nixos : name => {
      vmid = vm.vm_id
      ip   = var.vms[name].ip
    }
  }
}

output "ipv4_addresses" {
  description = "Addresses the guest agent reports for each VM, without loopback. A new VM on the installer ISO shows its DHCP address here. Run tofu refresh if the list is empty."
  value = {
    for name, vm in proxmox_virtual_environment_vm.nixos : name => [
      for ip in flatten(vm.ipv4_addresses) : ip if !startswith(ip, "127.")
    ]
  }
}

output "spool" {
  description = "VMID and address of the Tier 0 jump host, or null while it is not created."
  value = length(proxmox_virtual_environment_vm.spool) == 0 ? null : {
    vmid = proxmox_virtual_environment_vm.spool[0].vm_id
    ip   = var.spool.ip
  }
}
