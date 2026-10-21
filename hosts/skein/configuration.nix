# skein — patchwork_central, production (pve01 VMID 355, 10.100.90.55, 4 GB)
#
# Was an empty, AD-joined Ubuntu VM ("patchwork database VM" in
# jaspermayone/infra's Ansible inventory). Rebuilt as NixOS, and joined again
# by modules/ad-join. Keep its lnx-skein-* groups and its computer object; the
# new join resets the computer password. Before the install: remove skein from
# the Ansible linux.yml run, so Ansible does not configure it too.
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
  patchwork.banner.role = "central db";

  patchwork.centralDb = {
    enable = true;
    database = "patchwork_central";
    inherit (schema) apps sharedSchemas;
    # Tailnet only, as on seam. On the LAN every VLAN 90 host could reach
    # the port. On the tailnet the policy in jaspermayone/infra picks the
    # clients: alastor (Weave) and tag:patchwork-krater (weft).
    allowedCIDRs = [ "100.64.0.0/10" ];
    firewallInterfaces = [ "tailscale0" ];
  };

  # One secret per app: secrets/central-prod-<app>.age, the password only.
  # age.secrets = lib.genAttrs ... is added when the host key exists.

  system.stateVersion = "26.05";
}
