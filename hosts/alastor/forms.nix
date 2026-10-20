# Short links to external forms on forms.patchworklabs.org. Exported as
# nixosModules.forms-alastor.
#
# Each entry in `forms` sends https://forms.patchworklabs.org/<path> (with or
# without a trailing slash) to the form's URL with a temporary (302) redirect,
# so a form can move without browsers holding on to the old one. Any other
# path, the bare domain included, matches no router and gets Traefik's 404.
# To add a form, add a line to `forms`.
#
# What the importing host must provide:
#   - Traefik with the file provider on /etc/traefik/conf.d and a `cloudflare`
#     cert resolver and `hsts` middleware (infra's modules/traefik)
#
# DNS: `forms` in patchworklabsorg/dns, a proxied A record to alastor.
#
# To change any of this: merge here, then in infra run
#   nix flake update patchwork-infra
# and deploy alastor.
{ lib, pkgs, ... }:
let
  host = "forms.patchworklabs.org";

  forms = {
    # Project Ganymede application (Tally).
    ganymede = "https://tally.so/r/Np2DyQ";
  };

  # Router and middleware name for one form.
  name = path: "forms-${path}";
in
{
  environment.etc."traefik/conf.d/forms.toml".source = (pkgs.formats.toml { }).generate "forms.toml" {
    http = {
      routers = lib.mapAttrs' (
        path: _:
        lib.nameValuePair (name path) {
          rule = "Host(`${host}`) && (Path(`/${path}`) || Path(`/${path}/`))";
          entryPoints = [ "websecure" ];
          tls.certResolver = "cloudflare";
          middlewares = [
            "hsts"
            (name path)
          ];
          # Nothing behind it: the redirect middleware answers every request.
          service = "noop@internal";
        }
      ) forms;
      middlewares = lib.mapAttrs' (
        path: url:
        lib.nameValuePair (name path) {
          redirectRegex = {
            regex = ".*";
            replacement = url;
          };
        }
      ) forms;
    };
  };
}
