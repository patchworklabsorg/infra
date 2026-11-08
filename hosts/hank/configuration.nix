# hank — Stash host (pve01 VMID 362, 10.100.90.62, 6 GB, 80 GB disk)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-hank-admins get them. Only this
# host's key decrypts the Stash secrets.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-stash. The policy in jaspermayone/infra must let
# tag:patchwork-stash reach skein:5432 (prod) and hem:5432 (staging) only.
#
# The disk holds the archive (/data/stash and /data/stash-staging): 80 GB,
# more than the other app VMs. Memory: Chromium and LibreOffice run in the
# worker container, with a 3 GB limit.
#
# Built on 2026-11-08 with nixos-anywhere from the installer ISO. Its host key
# is in secrets/secrets.nix.
{ config, ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ./stash.nix
  ];

  networking.hostName = "hank";
  patchwork.lanAddress = "10.100.90.62";
  patchwork.banner.role = "stash host";

  virtualisation.docker.enable = true;

  # The containers run as uid 1000 (`rails` in the image) and own /data/stash.
  # Reserve that uid for a system account here, so NixOS gives the local login
  # accounts (modules/common) 1001 and up, and no person owns the archive.
  users.users.stash = {
    uid = 1000;
    group = "stash";
    isSystemUser = true;
    description = "Stash containers (uid of the image's rails user)";
  };
  users.groups.stash.gid = 1000;

  # The lab hosts do not use MagicDNS (modules/common, --accept-dns=false),
  # so *.ts.net names do not resolve here. The Stash env files connect to
  # skein and hem by tailnet name. The containers use the host network, and
  # Docker copies this /etc/hosts into each one at start. If skein or hem
  # joins the tailnet again, its address changes: update it here (and the
  # aliases in jaspermayone/infra tailscale/policy.hujson). Addresses from
  # `tailscale status` on 2026-11-08.
  networking.hosts = {
    "100.109.223.51" = [ "skein.wildebeest-stargazer.ts.net" ];
    "100.67.124.123" = [ "hem.wildebeest-stargazer.ts.net" ];
  };

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
    virtualHosts = {
      stash = {
        serverName = "stash.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.patchwork.services.stash.port}";
          # Artifact downloads redirect to a signed URL served by the same app:
          # a git bundle or a video can be large, and slow.
          extraConfig = ''
            proxy_read_timeout 300s;
            proxy_buffering off;
          '';
        };
      };
      stash-staging = {
        serverName = "stash-staging.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.patchwork.services.stash.staging.port}";
          extraConfig = ''
            proxy_read_timeout 300s;
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
