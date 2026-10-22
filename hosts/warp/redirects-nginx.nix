# nginx virtual hosts for ./redirects.nix. alastor terminates TLS and adds
# HSTS (nixosModules.edge-alastor), then sends plain HTTP over the tailnet.
{ lib, ... }:
{
  services.nginx.virtualHosts = lib.mapAttrs' (
    host: paths:
    lib.nameValuePair "redirect-${host}" {
      serverName = host;
      listen = [
        {
          addr = "0.0.0.0";
          port = 80;
        }
      ];
      locations =
        lib.concatMapAttrs (path: url: {
          "= ${path}".return = "302 ${url}";
          "= ${path}/".return = "302 ${url}";
        }) paths
        // {
          "/".return = "404";
        };
    }
  ) (import ./redirects.nix);
}
