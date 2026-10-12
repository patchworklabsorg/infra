# skein — patchwork_central, production (pve01 VMID 355, 10.100.90.55, 4 GB)
#
# Was an empty, AD-joined Ubuntu VM ("patchwork database VM" in
# jaspermayone/infra's Ansible inventory). Rebuilt as NixOS. Before the
# install: remove it from that inventory and delete its computer object and
# lnx-skein-* groups in patchwork.internal.
{ config, ... }:
let
  schema = (import ../central-db-schema.nix).central;
in
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ../../modules/central-db
  ];

  networking.hostName = "skein";
  patchwork.lanAddress = "10.100.90.55";

  patchwork.centralDb = {
    enable = true;
    database = "patchwork_central";
    inherit (schema) apps sharedSchemas;
    # Apps in the lab (warp) connect over the LAN; everything else over the
    # tailnet.
    allowedCIDRs = [
      "10.100.90.0/24"
      "100.64.0.0/10"
    ];
    firewallInterfaces = [
      "ens18"
      "tailscale0"
    ];
  };

  # One secret per app: secrets/central-prod-<app>.age, the password only.
  # age.secrets = lib.genAttrs ... is added when the host key exists.

  system.stateVersion = "26.05";
}
