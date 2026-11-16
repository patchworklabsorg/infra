# alastor as the public edge for Patchwork apps on the lab app VMs. Exported
# as nixosModules.edge-alastor. alastor terminates TLS and proxies plain HTTP
# over the tailnet to nginx on the app's VM. Same pattern as saker/Sentry in
# jaspermayone/infra.
#
# Weave stays on alastor (nixosModules.weave-alastor), so it has no route
# here. Import this module next to weave-alastor. One VM per app: add a route
# when the app runs on its VM, and remove the app's own alastor module in the
# same change in jaspermayone/infra.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tailnet = "wildebeest-stargazer.ts.net";
  kraterProduction = config.patchwork.edge.kraterProduction;

  # Krater's every-minute ping (`krater.services.network_watch` in Krater):
  # an HTTPS request to /healthz/edge over the path its runners report on
  # (Cloudflare, Traefik here, the tailnet to weft). While it arrives,
  # runners can reach Krater; when it stops, Krater holds what it would do
  # about machines whose runners went silent, and alerts. Production only
  # while its routes are on.
  kraterPingUrls = [
    "https://krater-staging.patchworklabs.org/healthz/edge"
  ]
  ++ lib.optional kraterProduction "https://krater.patchworklabs.org/healthz/edge";

  # <router name> = { backend = "<host>"; hosts = [ "<fqdn>" ... ]; };
  routes = {
    # Not `quilt`/`quilt-staging`: those were the router names of the old
    # Traefik fragment on alastor (quilt.toml), and the same name in two
    # files of the file provider collides.
    quilt-batting = {
      backend = "batting";
      hosts = [ "quilt.patchworklabs.org" ];
    };
    quilt-staging-batting = {
      backend = "batting";
      hosts = [ "quilt-staging.patchworklabs.org" ];
    };
    # Krater staging on weft (../weft/krater.nix): the portal and its S3
    # gateway. Not `krater`/`krater-storage`: the names of Krater's own
    # Traefik fragment, which a host that runs Krater with traefik.enable
    # would add. Production's routes are below, only while it is on.
    krater-staging-weft = {
      backend = "weft";
      hosts = [ "krater-staging.patchworklabs.org" ];
    };
    krater-staging-storage-weft = {
      backend = "weft";
      hosts = [ "krater-staging-storage.patchworklabs.org" ];
    };
    # Stash on hank (../hank/stash.nix): production and staging.
    stash-hank = {
      backend = "hank";
      hosts = [ "stash.patchworklabs.org" ];
    };
    stash-staging-hank = {
      backend = "hank";
      hosts = [ "stash-staging.patchworklabs.org" ];
    };
    # Selvage production on twill (../twill/selvage.nix). nginx on
    # twill passes /slack/, /up, and the admin web UI (/admin, /auth/,
    # /assets/, /cable).
    selvage-twill = {
      backend = "twill";
      hosts = [ "selvage.patchworklabs.org" ];
    };
    # Selvage staging on twill: its own vhost in nginx on twill, with the
    # same public paths as production.
    selvage-staging-twill = {
      backend = "twill";
      hosts = [ "selvage-staging.patchworklabs.org" ];
    };
    # Every host in ../warp/redirects.nix. A new path on an existing host
    # needs no change here.
    redirects = {
      backend = "warp";
      hosts = builtins.attrNames (import ../warp/redirects.nix);
    };
  }
  // lib.optionalAttrs kraterProduction {
    krater-weft = {
      backend = "weft";
      hosts = [ "krater.patchworklabs.org" ];
    };
    krater-storage-weft = {
      backend = "weft";
      hosts = [ "krater-storage.patchworklabs.org" ];
    };
  };
in
{
  # Set from the one switch for Krater production
  # (../weft/krater-production.nix). An option only so that the test can turn
  # the routes on: set the switch file, not this.
  options.patchwork.edge.kraterEdgePing = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Ping Krater's /healthz/edge every minute, so it knows its runners can reach it.";
  };

  options.patchwork.edge.kraterProduction = lib.mkOption {
    type = lib.types.bool;
    default = (import ../weft/krater-production.nix).enable;
    description = "Route krater.patchworklabs.org and krater-storage.patchworklabs.org to weft.";
  };

  config.systemd.services.krater-edge-ping = lib.mkIf config.patchwork.edge.kraterEdgePing {
    description = "Tell Krater its runners' path to it works";
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
    };
    # Every URL, even after one fails: staging and production are separate.
    script = ''
      status=0
      for url in ${lib.escapeShellArgs kraterPingUrls}; do
        curl -fsS -o /dev/null --max-time 20 "$url" || { echo "no answer from $url" >&2; status=1; }
      done
      exit $status
    '';
  };

  config.systemd.timers.krater-edge-ping = lib.mkIf config.patchwork.edge.kraterEdgePing {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "minutely";
      AccuracySec = "5s";
    };
  };

  config.environment.etc."traefik/conf.d/patchwork.toml".source =
    (pkgs.formats.toml { }).generate "patchwork.toml"
      {
        http = {
          routers = lib.mapAttrs (name: r: {
            rule = lib.concatMapStringsSep " || " (h: "Host(`${h}`)") r.hosts;
            entryPoints = [ "websecure" ];
            tls.certResolver = "cloudflare";
            middlewares = [ "hsts" ];
            service = name;
          }) routes;
          services = lib.mapAttrs (_: r: {
            loadBalancer.servers = [ { url = "http://${r.backend}.${tailnet}"; } ];
          }) routes;
        };
      };
}
