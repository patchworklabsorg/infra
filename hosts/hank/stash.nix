# Stash on hank: the instance settings and the agenix secrets. nginx on hank
# (./configuration.nix) fronts the ports, and alastor routes the public names
# here over the tailnet (nixosModules.edge-alastor).
#
# Network: the containers use the host network, and hank reaches
# skein.wildebeest-stargazer.ts.net:5432 (production) and
# hem.wildebeest-stargazer.ts.net:5432 (staging) over the tailnet, through
# the tag:patchwork-stash grants in jaspermayone/infra tailscale/policy.hujson.
#
# Before Stash runs:
#   - secrets/stash-env.age (jsp + hank) and secrets/central-prod-stash.age
#     (jsp + skein): `bin/new-stash-secrets production`, then deploy skein so
#     the stash role gets its password. The same for staging with hem.
#   - Stash's app in Weave (redirect URI https://stash.patchworklabs.org/auth/callback,
#     scopes openid profile email roles, plus introspect; app roles viewer,
#     archivist, admin). Fill WEAVE_CLIENT_ID and WEAVE_CLIENT_SECRET into the
#     env file: `cd secrets && agenix -e stash-env.age`.
#   - Weave has the `stash` scope, and Krater's app may request it.
#   - DNS for the two hostnames, proxied to alastor (patchworklabsorg/dns).
{ config, ... }:
{
  imports = [ ../../modules/stash ];

  # Recipients are in ../../secrets/secrets.nix (jsp + hank's host key).
  age.secrets = {
    stash-env = {
      file = ../../secrets/stash-env.age;
      mode = "400";
    };
    stash-staging-env = {
      file = ../../secrets/stash-staging-env.age;
      mode = "400";
    };
  };

  patchwork.services.stash = {
    enable = true;
    # Pin to ghcr.io/patchworklabsorg/stash:<sha> once a build is known good.
    image = "ghcr.io/patchworklabsorg/stash:main";
    # 3005 and 3006 are Quilt prod and staging on batting; 3007 and 3008 are
    # Stash here. The ports are per host, so this is only for the humans.
    port = 3007;
    environmentFile = config.age.secrets.stash-env.path;
    dataDir = "/data/stash";

    # stash-staging.patchworklabs.org: RAILS_ENV=staging, its own data dir,
    # patchwork_central on hem:5432, Weave staging. Deploy a new image with
    # `sudo systemctl restart stash-staging-web`.
    staging = {
      enable = true;
      image = "ghcr.io/patchworklabsorg/stash:main";
      port = 3008;
      environmentFile = config.age.secrets.stash-staging-env.path;
      dataDir = "/data/stash-staging";
      workerMemory = "2g";
      # Not secret, and extraEnv overrides the env file, so nobody can point
      # staging at production Weave from the env file.
      extraEnv = {
        WEAVE_ISSUER = "https://weave-staging.patchworklabs.org";
        STASH_HOSTS = "stash-staging.patchworklabs.org";
        # One capture at a time on staging: production's two plus this on 6 GB.
        GOOD_JOB_MAX_THREADS = "1";
      };
    };
  };
}
