# weft — Krater host (pve01 VMID 361, 10.100.90.61, 4 GB, 40 GB disk)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-weft-admins get them. Only this
# host's key decrypts the Krater secrets.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-krater. The policy in jaspermayone/infra lets tag:patchwork-krater
# reach skein:5432 (prod) only. hem (staging) gets a grant when it joins the tailnet.
{ config, lib, ... }:
let
  krater = config.patchwork.services.krater;
in
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ./krater.nix
  ];

  networking.hostName = "weft";
  patchwork.lanAddress = "10.100.90.61";
  patchwork.banner.role = "krater host";

  virtualisation.docker.enable = true;

  # 4 GB, a Python portal and worker, SeaweedFS, and image builds on the host:
  # zram gives room for a build without the OOM killer.
  zramSwap.enable = true;

  services.nginx = {
    enable = true;
    # Only alastor reaches this, over the tailnet. alastor terminated TLS and
    # set X-Forwarded-For and X-Forwarded-Proto (https); pass them on as they
    # are. recommendedProxySettings would set X-Forwarded-Proto to http.
    commonHttpConfig = ''
      set_real_ip_from 100.64.0.0/10;
      real_ip_header X-Forwarded-For;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
      proxy_set_header X-Forwarded-Host $host;
    '';
    # Krater's two hostnames, only while Krater is on (./krater.nix).
    virtualHosts = lib.mkIf krater.enable {
      krater = {
        serverName = krater.domain;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString krater.port}";
          # More than the 1 MB nginx default, for form posts to the portal.
          extraConfig = "client_max_body_size 50m;";
        };
      };
      # SeaweedFS S3 gateway. Browsers upload screenshots to it, and rented
      # machines their checkpoints and outputs: no size limit, and no
      # buffering of the request on disk.
      krater-storage = {
        serverName = krater.storage.domain;
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString krater.storage.port}";
          extraConfig = ''
            client_max_body_size 0;
            proxy_request_buffering off;
            proxy_buffering off;
          '';
        };
      };
    };
  };
  # nginx is a host service, so the NixOS firewall applies to it (Docker's
  # published ports would bypass it). Open only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  system.stateVersion = "26.05";
}
