output "vms" {
  description = "VMID and address of each managed VM."
  value = {
    for name, vm in proxmox_virtual_environment_vm.nixos : name => {
      vmid = vm.vm_id
      ip   = var.vms[name].ip
    }
  }
}
