# warp — Patchwork app host (pve01 VMID 356, 10.100.90.56, 6 GB)
#
# Runs Weave (prod + staging) and the Patchwork apps that come next. This is
# the job patchworklabsorg/core's never-built Core VM was meant to do; its
# team accounts are here. Public traffic arrives from alastor over the tailnet:
# alastor terminates TLS (nixosModules.edge-alastor) and sends plain HTTP to
# nginx on tailscale0:80, which routes by Host to the app's loopback port.
{ ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    # Off until the Weave cutover from alastor. Two Weave instances must not
    # run at the same time, and warp is not yet a recipient of the Weave
    # secrets. See the header of ./weave.nix.
    # ./weave.nix
  ];

  networking.hostName = "warp";
  patchwork.lanAddress = "10.100.90.56";
  patchwork.banner.role = "app host";
  patchwork.members = [ "dom" ];

  virtualisation.docker.enable = true;
  systemd.tmpfiles.rules = [ "d /opt/dots 0775 root admins - -" ];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    # Only alastor reaches this, over the tailnet. It already set
    # X-Forwarded-For and X-Forwarded-Proto; keep them.
    commonHttpConfig = ''
      set_real_ip_from 100.64.0.0/10;
      real_ip_header X-Forwarded-For;
    '';
    virtualHosts = {
      weave = {
        serverName = "idp.patchworklabs.org";
        serverAliases = [
          "weave.patchworklabs.org"
          "slack.patchworklabs.org"
        ];
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/".proxyPass = "http://127.0.0.1:3003";
      };
      weave-staging = {
        serverName = "weave-staging.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/".proxyPass = "http://127.0.0.1:3004";
      };
    };
  };
  # nginx is a host service, so the NixOS firewall applies to it (Docker's
  # published ports would bypass it). Open only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  system.stateVersion = "26.05";
}
