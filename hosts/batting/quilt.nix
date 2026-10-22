# Quilt on batting: the instance settings and the agenix secrets. nginx on
# batting (./configuration.nix) fronts the ports, and alastor routes the
# public names here over the tailnet (nixosModules.edge-alastor).
#
# Network: the containers use the host network, and batting reaches
# seam.wildebeest-stargazer.ts.net:5432 (production) and
# hem.wildebeest-stargazer.ts.net:5433 (staging) over the tailnet, through
# the tag:patchwork-quilt grants in jaspermayone/infra tailscale/policy.hujson.
{ config, ... }:
{
  imports = [ ../../modules/quilt ];

  # Recipients are in ../../secrets/secrets.nix (jsp + batting's host key).
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
