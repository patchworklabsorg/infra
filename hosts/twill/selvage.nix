# Selvage on twill: the instance settings and the agenix secrets. nginx on
# twill (./configuration.nix) fronts the port, and alastor routes the public
# name here over the tailnet (nixosModules.edge-alastor).
#
# Production only. There is no Selvage staging instance yet, so no
# selvage-staging-env.age and no route for a staging name. hem already has
# Selvage's central role (central-staging-selvage.age) for a later staging.
#
# Network: the containers use the host network, and twill reaches
# skein.wildebeest-stargazer.ts.net:5432 (patchwork_central) and
# seam.wildebeest-stargazer.ts.net:5432 (patchwork_central_restricted) over
# the tailnet, through the tag:patchwork-selvage grants in jaspermayone/infra
# tailscale/policy.hujson.
#
# Before Selvage runs (README.md, "Selvage on twill", has the full order):
#   - secrets/restricted-prod-selvage.age (jsp + seam) and
#     secrets/selvage-env.age (jsp + twill): `bin/new-selvage-secrets`, then
#     deploy seam so the selvage role there gets its password. skein already
#     has its password (central-prod-selvage.age).
#   - secrets/selvage-ghcr-token.age (jsp + twill), while the image package
#     is private.
#   - The Slack and Weave values in the env file:
#     `bin/set-env-secret selvage-env.age SLACK_SIGNING_SECRET ...`.
#   - DNS for selvage.patchworklabs.org, proxied to alastor
#     (patchworklabsorg/dns).
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
  ghcrFile = ../../secrets/selvage-ghcr-token.age;
  hasEnv = builtins.pathExists envFile;
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
  systemd.services = lib.mkIf hasEnv (
    let
      prod = builtins.hashFile "sha256" envFile;
    in
    {
      selvage-web.restartTriggers = [ prod ];
      selvage-worker.restartTriggers = [ prod ];
    }
  );

  patchwork.services.selvage = {
    enable = true;
    # Pin to ghcr.io/patchworklabsorg/selvage:<sha> once a build is known good.
    image = "ghcr.io/patchworklabsorg/selvage:main";
    # 3005 and 3006 are Quilt on batting, 3007 and 3008 Stash on hank. The
    # ports are per host, so this is only for the humans.
    port = 3009;
    # agenix's path for the secret `selvage-env`. A string, so that it is the
    # same before and after the file exists.
    environmentFile = "${config.age.secretsDir}/selvage-env";
    registryCredentialsFile = if hasGhcr then config.age.secrets.selvage-ghcr-token.path else null;
    # The pwlbot PAT, the same token as quilt-ghcr-token.age.
    registryUsername = "pwlbot";
  };
}
