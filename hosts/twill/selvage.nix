# Selvage on twill: the instance settings and the agenix secrets. nginx on
# twill (./configuration.nix) fronts the port, and alastor routes the public
# name here over the tailnet (nixosModules.edge-alastor).
#
# Production and staging. Staging (selvage-staging.patchworklabs.org) serves
# the staging Slack workspace through its own Slack app, with Weave staging
# and the staging clusters on hem. README.md, "Selvage staging", has its
# runbook.
#
# Network: the containers use the host network, and twill reaches
# skein.wildebeest-stargazer.ts.net:5432 (patchwork_central) and
# seam.wildebeest-stargazer.ts.net:5432 (patchwork_central_restricted) for
# production, and hem.wildebeest-stargazer.ts.net:5432 and :5433 for staging,
# over the tailnet, through the tag:patchwork-selvage grants in
# jaspermayone/infra tailscale/policy.hujson.
#
# Before Selvage runs (README.md, "Selvage on twill", has the full order):
#   - secrets/restricted-prod-selvage.age (jsp + seam) and
#     secrets/selvage-env.age (jsp + twill): `bin/new-selvage-secrets`, then
#     deploy seam so the selvage role there gets its password. skein already
#     has its password (central-prod-selvage.age).
#   - secrets/selvage-ghcr-token.age (jsp + twill), while the image package
#     is private.
#   - The Slack and Weave values in the env file:
#     `bin/set-env-secret selvage-env.age SLACK_SIGNING_SECRET ...`. The
#     units do not start without SLACK_SIGNING_SECRET and SLACK_BOT_TOKEN.
#   - DNS for selvage.patchworklabs.org, proxied to alastor
#     (patchworklabsorg/dns).
#   - For staging: secrets/restricted-staging-selvage.age (jsp + hem) and
#     secrets/selvage-staging-env.age (jsp + twill), written by
#     `bin/new-selvage-staging-secrets`, then deploy hem. The staging Slack
#     app's values go in the staging env file.
#
# Each secret is declared only when its .age file exists, so twill builds
# before the secrets are written. Until the env file decrypts on twill, the
# units do not start (ConditionPathExists in modules/selvage).
{
  config,
  lib,
  ...
}:
let
  envFile = ../../secrets/selvage-env.age;
  stagingEnvFile = ../../secrets/selvage-staging-env.age;
  ghcrFile = ../../secrets/selvage-ghcr-token.age;
  hasEnv = builtins.pathExists envFile;
  hasStagingEnv = builtins.pathExists stagingEnvFile;
  hasGhcr = builtins.pathExists ghcrFile;
in
{
  imports = [ ../../modules/selvage ];

  # Recipients are in ../../secrets/secrets.nix (jsp + twill's host key).
  age.secrets =
    lib.optionalAttrs hasEnv {
      selvage-env = {
        file = envFile;
        mode = "400";
      };
    }
    // lib.optionalAttrs hasStagingEnv {
      selvage-staging-env = {
        file = stagingEnvFile;
        mode = "400";
      };
    }
    // lib.optionalAttrs hasGhcr {
      # GitHub classic PAT with read:packages, for the private image.
      selvage-ghcr-token = {
        file = ghcrFile;
        mode = "400";
      };
    };

  # The containers read their env file only when they start, and the file's
  # path never changes, so a new secret alone restarts nothing. Restart the
  # units when the encrypted file changes, so an `agenix -e` reaches Selvage
  # on the next switch. The trigger is the file's hash, not its path: the path
  # is inside the flake's source, which changes on every commit.
  systemd.services = lib.mkMerge [
    (lib.mkIf hasEnv (
      let
        prod = builtins.hashFile "sha256" envFile;
      in
      {
        selvage-web.restartTriggers = [ prod ];
        selvage-worker.restartTriggers = [ prod ];
      }
    ))
    (lib.mkIf hasStagingEnv (
      let
        staging = builtins.hashFile "sha256" stagingEnvFile;
      in
      {
        selvage-staging-web.restartTriggers = [ staging ];
        selvage-staging-worker.restartTriggers = [ staging ];
      }
    ))
  ];

  patchwork.services.selvage = {
    enable = true;
    # Pin to ghcr.io/patchworklabsorg/selvage:<sha> once a build is known good.
    image = "ghcr.io/patchworklabsorg/selvage:main";
    # 3005 and 3006 are Quilt on batting, 3007 and 3008 Stash on hank, 3010
    # Selvage staging here. The ports are per host, so this is only for the
    # humans.
    port = 3009;
    # agenix's path for the secret `selvage-env`. A string, so that it is the
    # same before and after the file exists.
    environmentFile = "${config.age.secretsDir}/selvage-env";
    registryCredentialsFile = if hasGhcr then config.age.secrets.selvage-ghcr-token.path else null;
    # The pwlbot PAT, the same token as quilt-ghcr-token.age. Staging uses
    # the same login.
    registryUsername = "pwlbot";

    # selvage-staging.patchworklabs.org: selvage-staging-web and
    # selvage-staging-worker on 127.0.0.1:3010, with RAILS_ENV=staging, the
    # same image as production. Its databases are on hem (5432 and 5433).
    # Deploy a new image with `sudo systemctl restart selvage-staging-web`.
    staging = {
      enable = true;
      image = "ghcr.io/patchworklabsorg/selvage:main";
      port = 3010;
      environmentFile = "${config.age.secretsDir}/selvage-staging-env";
      # twill has 3 GB. Production has no limit. Each staging container gets
      # at most 512 MB, so staging cannot take production's memory.
      memory = "512m";
      # Not secret, and extraEnv overrides the env file, so nobody can point
      # staging at production Weave from the env file.
      extraEnv = {
        WEAVE_ISSUER = "https://weave-staging.patchworklabs.org";
        SELVAGE_HOSTS = "selvage-staging.patchworklabs.org";
      };
    };
  };
}
