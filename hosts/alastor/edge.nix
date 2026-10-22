# alastor as the public edge for Patchwork apps on the lab app VMs. Exported
# as nixosModules.edge-alastor. alastor terminates TLS and proxies plain HTTP
# over the tailnet to nginx on the app's VM. Same pattern as saker/Sentry in
# jaspermayone/infra.
#
# Weave stays on alastor (nixosModules.weave-alastor), so it has no route
# here. Import this module next to weave-alastor. One VM per app: add a route
# when the app runs on its VM, and remove the app's own alastor module in the
# same change in jaspermayone/infra.
{ lib, pkgs, ... }:
let
  tailnet = "wildebeest-stargazer.ts.net";

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
    # gateway. Krater has no production instance yet. Not `krater`/
    # `krater-storage`: the names of Krater's own Traefik fragment, which a
    # host that runs Krater with traefik.enable would add.
    krater-staging-weft = {
      backend = "weft";
      hosts = [ "krater-staging.patchworklabs.org" ];
    };
    krater-staging-storage-weft = {
      backend = "weft";
      hosts = [ "krater-staging-storage.patchworklabs.org" ];
    };
    # Every host in ../warp/redirects.nix. A new path on an existing host
    # needs no change here.
    redirects = {
      backend = "warp";
      hosts = builtins.attrNames (import ../warp/redirects.nix);
    };
  };
in
{
  environment.etc."traefik/conf.d/patchwork.toml".source =
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
