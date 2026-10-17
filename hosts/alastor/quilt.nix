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
#     (production) and hem.wildebeest-stargazer.ts.net:5433 (staging)
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
    # The staging env file. The password in RESTRICTED_DATABASE_URL must
    # equal restricted-staging-quilt.age (hem). The Mercury tokens are sandbox
    # tokens and the Weave client is a Weave staging app.
    quilt-staging-env = {
      file = ../../secrets/quilt-staging-env.age;
      mode = "400";
    };
    # GitHub classic PAT with read:packages, for the private image. Production
    # and staging use the same login.
    quilt-ghcr-token = {
      file = ../../secrets/quilt-ghcr-token.age;
      mode = "400";
    };
  };

  patchwork.services.quilt = {
    enable = true;
    # Pin to ghcr.io/patchworklabsorg/quilt:<sha> once a build is known good.
    image = "ghcr.io/patchworklabsorg/quilt:main";
    # The pwlbot PAT in quilt-ghcr-token.age.
    registryUsername = "pwlbot";
    # 3003 and 3004 are Weave prod and staging. 3006 is Quilt staging.
    port = 3005;
    environmentFile = config.age.secrets.quilt-env.path;
    registryCredentialsFile = config.age.secrets.quilt-ghcr-token.path;

    traefik = {
      enable = true;
      hosts = [ "quilt.patchworklabs.org" ];
    };

    # quilt-staging.patchworklabs.org: quilt-staging-web and
    # quilt-staging-worker on 127.0.0.1:3006, with RAILS_ENV=staging. Quilt
    # refuses to boot in staging unless MERCURY_API_BASE is the sandbox, so
    # staging cannot move real money. Its database is
    # patchwork_central_restricted on hem:5433. Deploy a new image with
    # `sudo systemctl restart quilt-staging-web`.
    staging = {
      enable = true;
      image = "ghcr.io/patchworklabsorg/quilt:main";
      port = 3006;
      environmentFile = config.age.secrets.quilt-staging-env.path;
      hosts = [ "quilt-staging.patchworklabs.org" ];
      # Not secret, so they live here and not in the env file. extraEnv
      # overrides the env file, so nobody can point staging at the live
      # Mercury API or at production Weave from the env file.
      extraEnv = {
        MERCURY_API_BASE = "https://api-sandbox.mercury.com/api/v1/";
        WEAVE_ISSUER = "https://weave-staging.patchworklabs.org";
      };
    };
  };
}
