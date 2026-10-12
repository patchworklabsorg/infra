# hem — both staging clusters (pve01 VMID 358, 10.100.90.58, 2 GB; VMID and
# address to be confirmed free before create)
#
# patchwork_central on 5432 and patchwork_central_restricted on 5433, each in
# its own NixOS container, so they are two clusters with separate data
# directories, superusers and pg_hba, like prod. The containers share the
# host's network, so the ports must differ.
{ lib, ... }:
let
  schemas = import ../central-db-schema.nix;

  cluster = database: port: allowedCIDRs: schema: {
    autoStart = true;
    # Host network: the container's Postgres listens on the host's interfaces.
    privateNetwork = false;
    bindMounts."/run/agenix/${database}" = {
      hostPath = "/run/agenix/${database}";
      isReadOnly = true;
    };
    config =
      { ... }:
      {
        imports = [ ../../modules/central-db ];
        patchwork.centralDb = {
          enable = true;
          inherit database port allowedCIDRs;
          inherit (schema) apps sharedSchemas;
          # The host firewall below opens the ports. The container has none.
          firewallInterfaces = [ ];
        };
        networking.firewall.enable = false;
        system.stateVersion = "26.05";
      };
  };
in
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
  ];

  networking.hostName = "hem";
  patchwork.lanAddress = "10.100.90.58";

  # Same reach as prod: central from the LAN and the tailnet, restricted from
  # the tailnet only.
  containers.central-staging = cluster "patchwork_central" 5432 [
    "10.100.90.0/24"
    "100.64.0.0/10"
  ] schemas.central;
  containers.restricted-staging = cluster "patchwork_central_restricted" 5433 [
    "100.64.0.0/10"
  ] schemas.restricted;

  networking.firewall.interfaces = {
    ens18.allowedTCPPorts = [ 5432 ];
    tailscale0.allowedTCPPorts = [
      5432
      5433
    ];
  };

  system.stateVersion = "26.05";
}
