# twill — Selvage host (pve01 VMID 363, 10.100.90.63, 3 GB, 20 GB disk):
# production and staging.
#
# One app per VM. Selvage holds a Slack admin token (xoxp) and reads the
# restricted database, so sudo and the docker group here are root over both.
# Only the break-glass admins (modules/common) and lnx-twill-admins get them.
# Only this host's key decrypts the Selvage env file.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-selvage. The policy in jaspermayone/infra must let
# tag:patchwork-selvage reach skein:5432, seam:5432 (production) and
# hem:5432, hem:5433 (staging) only.
{ config, ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ./selvage.nix
  ];

  networking.hostName = "twill";
  patchwork.lanAddress = "10.100.90.63";
  patchwork.banner.role = "selvage host";

  virtualisation.docker.enable = true;

  # The lab hosts do not use MagicDNS (modules/common, --accept-dns=false),
  # so *.ts.net names do not resolve here. The Selvage env file connects to
  # skein and seam (production) and hem (staging) by tailnet name. The containers use the host network, and
  # Docker copies this /etc/hosts into each one at start. If skein or seam
  # joins the tailnet again, its address changes: update it here (and the
  # aliases in jaspermayone/infra tailscale/policy.hujson). hem's address is
  # the same as in hosts/batting and hosts/hank.
  networking.hosts = {
    "100.109.223.51" = [ "skein.wildebeest-stargazer.ts.net" ];
    "100.87.183.57" = [ "seam.wildebeest-stargazer.ts.net" ];
    "100.67.124.123" = [ "hem.wildebeest-stargazer.ts.net" ];
  };

  zramSwap.enable = true;

  services.nginx =
    let
      upstream = "http://127.0.0.1:${toString config.patchwork.services.selvage.port}";

      # The public paths of a Selvage web server, for one upstream. Slack calls
      # the three request URLs under /slack/ (POST only), and the health check
      # is GET /up. The moderator web UI lives under /admin, its weave login
      # under /auth, its assets under /assets, and its live updates on /cable.
      # The app checks the weave role on every /admin request. Nothing else of
      # the app is public. The production and staging vhosts both use it.
      selvageLocations = backend: {
        "/slack/" = {
          proxyPass = backend;
          extraConfig = ''
            limit_except POST { deny all; }
          '';
        };
        "= /up".proxyPass = backend;
        "= /admin".proxyPass = backend;
        "/admin/".proxyPass = backend;
        "/auth/".proxyPass = backend;
        "/assets/".proxyPass = backend;
        # Turbo Streams for live updates in the admin UI (Action Cable).
        # proxyWebsockets sets proxy_set_header in this location, and nginx
        # then drops the http-level ones here, so set them again. Action Cable
        # checks the Origin against the Host.
        "= /cable" = {
          proxyPass = backend;
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;
            proxy_set_header X-Forwarded-Host $host;
          '';
        };
        "/".return = "404";
      };
    in
    {
      enable = true;
      # A change to the nginx config reloads nginx, not restarts it, so a
      # change to the staging vhost does not drop production's Slack requests.
      enableReload = true;
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
      virtualHosts.selvage = {
        serverName = "selvage.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations = selvageLocations upstream;
      };
      # Selvage staging, the same paths on its own port.
      virtualHosts.selvage-staging = {
        serverName = "selvage-staging.patchworklabs.org";
        listen = [
          {
            addr = "0.0.0.0";
            port = 80;
          }
        ];
        locations = selvageLocations "http://127.0.0.1:${toString config.patchwork.services.selvage.staging.port}";
      };
    };
  # nginx is a host service, so the NixOS firewall applies to it (Docker's
  # published ports would bypass it). Open only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  system.stateVersion = "26.05";
}
