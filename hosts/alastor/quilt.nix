# Quilt on alastor. Exported as nixosModules.quilt-alastor.
#
# alastor is jaspermayone's VPS and is built from jaspermayone/infra, which
# imports this module through its `patchwork-infra` flake input. Everything
# Patchwork-specific about the deployment lives here: the instance settings,
# the Traefik route and the agenix secrets.
#
# What the importing host must provide:
#   - the agenix NixOS module (`age.*` options)
#   - Docker (the module runs its containers through it)
#   - Traefik with the file provider on /etc/traefik/conf.d and a `cloudflare`
#     cert resolver and `hsts` middleware (infra's modules/traefik)
#   - Tailscale, so the host reaches seam.wildebeest-stargazer.ts.net:5432
#
# To change any of this: merge here, then in infra run
#   nix flake update patchwork-infra
# and deploy alastor.
{ config, ... }:
{
  imports = [ ../../modules/quilt ];

  # Recipients are in ../../secrets/secrets.nix (jsp + alastor's host key).
  age.secrets = {
    # Every variable in docs/deploy.md of patchworklabsorg/quilt. The
    # password in RESTRICTED_DATABASE_URL must equal restricted-prod-quilt.age.
    quilt-env = {
      file = ../../secrets/quilt-env.age;
      mode = "400";
    };
    # GitHub classic PAT with read:packages, for the private image.
    quilt-ghcr-token = {
      file = ../../secrets/quilt-ghcr-token.age;
      mode = "400";
    };
  };

  patchwork.services.quilt = {
    enable = true;
    # Pin to ghcr.io/patchworklabsorg/quilt:<sha> once a build is known good.
    image = "ghcr.io/patchworklabsorg/quilt:main";
    # 3003 and 3004 are Weave prod and staging.
    port = 3005;
    environmentFile = config.age.secrets.quilt-env.path;
    registryCredentialsFile = config.age.secrets.quilt-ghcr-token.path;

    traefik = {
      enable = true;
      hosts = [ "quilt.patchworklabs.org" ];
    };
  };
}
