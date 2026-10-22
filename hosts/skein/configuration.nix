# skein — patchwork_central, production (pve01 VMID 355, 10.100.90.55, 4 GB)
#
# Was an empty, AD-joined Ubuntu VM ("patchwork database VM" in
# jaspermayone/infra's Ansible inventory). Rebuilt as NixOS, and joined again
# by modules/ad-join. Keep its lnx-skein-* groups and its computer object; the
# new join resets the computer password. Before the install: remove skein from
# the Ansible linux.yml run, so Ansible does not configure it too.
{ config, lib, ... }:
let
  schema = (import ../central-db-schema.nix).central;

  # secrets/central-prod-<app>.age for each app that has one. An app without a
  # file gets a role that cannot log in yet (modules/central-db).
  passwordFiles = lib.filterAttrs (_: builtins.pathExists) (
    lib.mapAttrs (app: _: ../../secrets/central-prod-${app}.age) schema.apps
  );
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
    # clients: tag:patchwork-krater (weft). Weave uses its own database.
    allowedCIDRs = [ "100.64.0.0/10" ];
    firewallInterfaces = [ "tailscale0" ];
  };

  # Each password lands at <passwordDir>/<app>, where central-db-setup reads it
  # as postgres. skein's host key must be a recipient (secrets/secrets.nix).
  age.secrets = lib.mapAttrs' (
    app: file:
    lib.nameValuePair "central-prod-${app}" {
      inherit file;
      path = "${config.patchwork.centralDb.passwordDir}/${app}";
      owner = "postgres";
      mode = "400";
    }
  ) passwordFiles;

  # Set the password again when its secret changes.
  systemd.services.central-db-setup.restartTriggers = builtins.attrValues passwordFiles;

  system.stateVersion = "26.05";
}
