# weft — Krater host (pve01 VMID 361, 10.100.90.61, 4 GB, 40 GB disk)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-weft-admins get them. Only this
# host's key decrypts the Krater secrets (staging and production).
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-krater. The policy in jaspermayone/infra lets tag:patchwork-krater
# reach hem:5432 (central staging). Krater staging runs here (./krater.nix)
# and uses hem only. Krater production is ready but off
# (./krater-production.nix); it needs a grant to skein:5432 when it goes on.
#
# Built on 2026-10-22 with `qm create`, `tofu import` and nixos-anywhere. Its
# host key is a recipient of ad-join.age (AD logon).
{ config, lib, ... }:
let
  krater = config.patchwork.services.krater;
  kraterProd = config.patchwork.services.krater-production;
  listen = [
    {
      addr = "0.0.0.0";
      port = 80;
    }
  ];
  # The portal and its SeaweedFS S3 gateway. Browsers upload screenshots to
  # the gateway, and rented machines their checkpoints and outputs: no size
  # limit here (Cloudflare caps a request at 100 MB), and no buffering of the
  # request on disk.
  kraterVhosts = name: k: {
    ${name} = {
      serverName = k.domain;
      inherit listen;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString k.port}";
        # More than the 1 MB nginx default, for form posts to the portal.
        extraConfig = "client_max_body_size 50m;";
      };
    };
    "${name}-storage" = {
      serverName = k.storage.domain;
      inherit listen;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString k.storage.port}";
        extraConfig = ''
          client_max_body_size 0;
          proxy_request_buffering off;
          proxy_buffering off;
        '';
      };
    };
  };
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
    # set X-Forwarded-For and X-Forwarded-Proto (https). Pass the proto on as
    # it is (recommendedProxySettings would set http), and append alastor's
    # address to X-Forwarded-For. No real_ip here: Krater reads the client
    # from X-Forwarded-For itself (KRATER_TRUSTED_PROXY_COUNT in ./krater.nix).
    commonHttpConfig = ''
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
      proxy_set_header X-Forwarded-Host $host;
    '';
    # Krater's hostnames, each instance only while it is on (./krater.nix).
    virtualHosts = lib.mkMerge [
      {
        # An unknown Host, or a name whose instance is off, gets no answer
        # (444): it never falls through to the first vhost, the staging portal.
        catch-all = {
          default = true;
          serverName = "_";
          inherit listen;
          locations."/".return = "444";
        };
      }
      (lib.mkIf krater.enable (kraterVhosts "krater" krater))
      (lib.mkIf kraterProd.enable (kraterVhosts "krater-prod" kraterProd))
    ];
  };
  # nginx is a host service, so the NixOS firewall applies to it (Docker's
  # published ports would bypass it). Open only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  system.stateVersion = "26.05";
}
