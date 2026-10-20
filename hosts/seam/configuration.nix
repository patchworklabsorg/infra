# seam — patchwork_central_restricted, production (pve01 VMID 357,
# 10.100.90.57, 2 GB; VMID and address to be confirmed free before create)
#
# A cluster on its own VM, so it has its own superuser, backups and pg_hba.
# Tailnet only: the port is closed on the LAN, so a lab VM without a tailnet
# grant cannot reach it.
{ config, lib, ... }:
let
  schema = (import ../central-db-schema.nix).restricted;

  # secrets/restricted-prod-<app>.age for each app that has one. An app
  # without a file gets a role that cannot log in yet (modules/central-db).
  passwordFiles = lib.filterAttrs (_: builtins.pathExists) (
    lib.mapAttrs (app: _: ../../secrets/restricted-prod-${app}.age) schema.apps
  );
in
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ../../modules/central-db
  ];

  networking.hostName = "seam";
  patchwork.lanAddress = "10.100.90.57";
  patchwork.banner = {
    enable = true;
    role = "restricted central db";
  };

  patchwork.centralDb = {
    enable = true;
    database = "patchwork_central_restricted";
    inherit (schema) apps sharedSchemas;
    allowedCIDRs = [ "100.64.0.0/10" ];
    firewallInterfaces = [ "tailscale0" ];
  };

  # Each password lands at <passwordDir>/<app>, where central-db-setup reads it
  # as postgres. seam's host key must be a recipient (secrets/secrets.nix).
  age.secrets = lib.mapAttrs' (
    app: file:
    lib.nameValuePair "restricted-prod-${app}" {
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
