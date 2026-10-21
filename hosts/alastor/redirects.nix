# alastor's route to the redirect server on warp. Exported as
# nixosModules.redirects-alastor. Separate from edge-alastor, so the redirects
# can go live before the Weave cutover: importing edge-alastor also moves
# Weave's hosts to warp.
#
# alastor terminates TLS, adds HSTS and proxies plain HTTP over the tailnet to
# nginx on warp (../warp/redirects-nginx.nix). The hosts come from
# ../warp/redirects.nix, so a new path on an existing host needs no change
# here. A new host needs `nix flake update patchwork-infra` and an alastor
# deploy in jaspermayone/infra.
{ lib, pkgs, ... }:
let
  tailnet = "wildebeest-stargazer.ts.net";
  hosts = builtins.attrNames (import ../warp/redirects.nix);
in
{
  environment.etc."traefik/conf.d/redirects.toml".source =
    (pkgs.formats.toml { }).generate "redirects.toml"
      {
        http = {
          routers.redirects = {
            rule = lib.concatMapStringsSep " || " (h: "Host(`${h}`)") hosts;
            entryPoints = [ "websecure" ];
            tls.certResolver = "cloudflare";
            middlewares = [ "hsts" ];
            service = "redirects";
          };
          services.redirects.loadBalancer.servers = [ { url = "http://warp.${tailnet}"; } ];
        };
      };
}
