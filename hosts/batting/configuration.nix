# batting — Quilt host (pve01 VMID 360, 10.100.90.60, 4 GB)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-batting-admins get them. Only this
# host's key decrypts the Quilt secrets.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-quilt. The policy in jaspermayone/infra lets tag:patchwork-quilt
# reach seam:5432 (prod) and hem:5433 (staging) only.
{ ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ./quilt.nix
  ];

  networking.hostName = "batting";
  patchwork.lanAddress = "10.100.90.60";
  patchwork.banner.role = "quilt host";

  virtualisation.docker.enable = true;

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
      quilt = {
        serverName = "quilt.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/".proxyPass = "http://127.0.0.1:3005";
      };
      quilt-staging = {
        serverName = "quilt-staging.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/".proxyPass = "http://127.0.0.1:3006";
      };
    };
  };
  # nginx is a host service, so the NixOS firewall applies to it (Docker's
  # published ports would bypass it). Open only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  system.stateVersion = "26.05";
}
