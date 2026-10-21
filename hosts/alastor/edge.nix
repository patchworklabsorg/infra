# alastor as the public edge for Patchwork apps on lab hosts. Exported as
# nixosModules.edge-alastor. alastor terminates TLS and proxies plain HTTP
# over the tailnet to nginx on the app host. Same pattern as saker/Sentry in
# jaspermayone/infra.
#
# Import this INSTEAD of nixosModules.weave-alastor once Weave runs on warp.
# The router names stay `idp` and `weave-staging`.
{ lib, pkgs, ... }:
let
  tailnet = "wildebeest-stargazer.ts.net";

  routes = {
    idp = {
      backend = "warp";
      hosts = [
        "idp.patchworklabs.org"
        "weave.patchworklabs.org"
        "slack.patchworklabs.org"
      ];
    };
    weave-staging = {
      backend = "warp";
      hosts = [ "weave-staging.patchworklabs.org" ];
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
