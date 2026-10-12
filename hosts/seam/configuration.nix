# seam — patchwork_central_restricted, production (pve01 VMID 357,
# 10.100.90.57, 2 GB; VMID and address to be confirmed free before create)
#
# A cluster on its own VM, so it has its own superuser, backups and pg_hba.
# Tailnet only: the port is closed on the LAN, so a lab VM without a tailnet
# grant cannot reach it.
{ config, ... }:
let
  schema = (import ../central-db-schema.nix).restricted;
in
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ../../modules/central-db
  ];

  networking.hostName = "seam";
  patchwork.lanAddress = "10.100.90.57";

  patchwork.centralDb = {
    enable = true;
    database = "patchwork_central_restricted";
    inherit (schema) apps sharedSchemas;
    allowedCIDRs = [ "100.64.0.0/10" ];
    firewallInterfaces = [ "tailscale0" ];
  };

  system.stateVersion = "26.05";
}
