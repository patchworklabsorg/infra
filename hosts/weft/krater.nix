# Krater on weft: staging and production, with their settings and agenix
# secrets. nginx on weft (./configuration.nix) fronts the ports, and alastor
# routes the public names here over the tailnet (nixosModules.edge-alastor).
# Staging runs now. Production is ready but off: ./krater-production.nix is
# its one switch.
#
# Staging follows the Patchwork staging standard: its own database (the
# `krater` schema in patchwork_central on hem:5432), Weave staging for sign-in,
# and its own hostnames. Krater Compute stays off, so no Vast account is used.
# KRATER_ENV is `production` here, which only turns on Krater's production
# checks. KRATER_STAGING turns on the hazard-stripe frame and the STAGING tab,
# the same as Weave and Quilt staging (needs patchworklabsorg/krater with
# that setting; an older build ignores it).
#
# Network: the containers are on the `krater` bridge network. weft reaches
# hem.wildebeest-stargazer.ts.net:5432 over the tailnet, through the
# tag:patchwork-krater grant in jaspermayone/infra tailscale/policy.hujson.
# weft has no MagicDNS, so `extraHosts` gives the containers hem's tailnet
# address.
#
# Before Krater staging runs (Krater stays off until the env file and the
# Weave client id both exist, so weft builds and deploys without them).
# Deploy once with the id empty, and run `systemctl start krater-build` by
# hand: the first build takes minutes. Then set the id and deploy again:
#   - secrets/krater-staging-env.age (jsp + weft) and
#     secrets/central-staging-krater.age (jsp + hem): run
#     `bin/new-krater-secrets staging`, then deploy hem so the krater role
#     gets its password
#   - Krater's app in Weave staging; fill in `weaveClientId` below, and the
#     client secret and the Slack values in krater-staging-env.age. The Slack
#     values must come from a separate Slack app in a test workspace, never
#     from the real Patchwork workspace.
#   - DNS for the two hostnames below, proxied to alastor (patchworklabsorg/dns)
# The full checklist is in Krater's docs/dev/production.md.
#
# Krater Compute stays off (KRATER_COMPUTE_MODE=off) until Krater's paid checks
# pass (its docs/compute/README.md). Turning it on: put a Vast key in
# secrets/krater-staging-vast-key.age, uncomment the secret below, and set
# compute.enable and compute.vastKeyFile.
#
# Project secrets (a member's HF_TOKEN for their jobs) need
# secrets/krater-staging-project-secrets-key.age: one Fernet key per line,
# newest first. Make one with
#   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# Back it up with the other agenix secrets: losing it loses every stored
# project secret.
# Production (patchwork.services.krater-production, names krater-prod-*,
# ports 3012/3013, the `krater` schema in patchwork_central on skein, Weave
# production). Turn on production:
#   1. Krater's app in Weave production exists, and its client id is in
#      `productionWeaveClientId` below. Fill in the empty keys of
#      secrets/krater-env.age (`cd secrets && agenix -e krater-env.age`):
#      KRATER_WEAVE_CLIENT_SECRET, and KRATER_SLACK_BOT_TOKEN and
#      KRATER_SLACK_SIGNING_SECRET from the real Patchwork Slack app. The file
#      exists already (bin/new-krater-secrets production), so the build does
#      not check these: Krater's settings check fails the unit if one is empty.
#   2. jaspermayone/infra tailscale/policy.hujson: give tag:patchwork-krater
#      pw-skein:5432 again (the grant and the test lines are in #32's body).
#   3. Set `enable = true` in ./krater-production.nix. That also puts krater
#      in `apps` for skein (../central-db-schema.nix) and adds the alastor
#      routes (../alastor/edge.nix).
#   4. Deploy skein (the role gets the password in central-prod-krater.age),
#      then weft once, then `systemctl start krater-prod-build` by hand.
#   5. DNS: krater and krater-storage, proxied to alastor (patchworklabsorg/dns).
#   6. Bump patchwork-infra in jaspermayone/infra and deploy alastor.
{ lib, ... }:
let
  # Staging: Weave staging (https://weave-staging.patchworklabs.org). The client
  # id of Krater's app there (redirect URI
  # https://krater-staging.patchworklabs.org/auth/callback). Not secret.
  stagingWeaveIssuer = "https://weave-staging.patchworklabs.org";
  stagingWeaveClientId = "vTt8nTKFw7Qau8S2aBfhXrBQuCi1PbduyF0x6sH5QJo";

  # Production: Weave production (https://weave.patchworklabs.org). The client
  # id of Krater's app there (redirect URI
  # https://krater.patchworklabs.org/auth/callback). Not secret. Setting it does
  # not turn production on: ./krater-production.nix does.
  productionWeaveIssuer = "https://weave.patchworklabs.org";
  productionWeaveClientId = "GwmIPZenHuqRjUjawfJyDYceEcdXDJibTbmEEkuRJDU";

  envFile = ../../secrets/krater-staging-env.age;
  enable = stagingWeaveClientId != "" && builtins.pathExists envFile;

  production = import ./krater-production.nix;
  prodEnvFile = ../../secrets/krater-env.age;
  prodEnable = production.enable;

  # The proxies that each append one address to X-Forwarded-For: Cloudflare
  # (the client), Traefik on alastor (Cloudflare's edge) and nginx on weft
  # (alastor's tailnet address). Krater sees "client, cf_ip, alastor_ip" and
  # takes the third address from the right as the client. nginx on weft
  # does no real_ip rewrite (./configuration.nix), so the chain stays whole.
  trustedProxyCount = "3";
in
{
  imports = [ ../../modules/krater ];

  assertions = [
    {
      assertion = prodEnable -> productionWeaveClientId != "";
      message = "hosts/weft/krater-production.nix turns Krater production on, but productionWeaveClientId in hosts/weft/krater.nix is empty";
    }
  ];

  # Recipients are in ../../secrets/secrets.nix (jsp + weft's host key).
  age.secrets = lib.mkMerge [
    (lib.mkIf prodEnable {
      krater-env = {
        file = prodEnvFile;
        mode = "400";
      };
    })
    (lib.mkIf (builtins.pathExists envFile) {
      krater-staging-env = {
        file = envFile;
        mode = "400";
      };
      # krater-staging-project-secrets-key = {
      #   file = ../../secrets/krater-staging-project-secrets-key.age;
      #   mode = "400";
      # };
      # krater-staging-vast-key = {
      #   file = ../../secrets/krater-staging-vast-key.age;
      #   mode = "400";
      # };
    })
  ];

  patchwork.services.krater = {
    inherit enable;
    # agenix's default path for the secret above.
    environmentFile = "/run/agenix/krater-staging-env";

    # Fallback build; deploys write /var/lib/krater/source-rev instead. A
    # commit on Krater's main (2026-10-22, after patchworklabsorg/krater#9).
    rev = "b081a132fe1e6c2b8d998f45a65e507745052300";

    # One level under patchworklabs.org: the records are proxied through
    # Cloudflare, whose edge certificate covers only one subdomain level.
    # Added by a PR to patchworklabsorg/dns, like weave-staging's.
    domain = "krater-staging.patchworklabs.org";
    storage.domain = "krater-staging-storage.patchworklabs.org";
    # weft's 40 GB disk holds the system, two SeaweedFS stores (staging and
    # production), two image repositories (krater, krater-prod) and the shared
    # BuildKit cache. So each store gets at most 8 volumes of 1 GB. Cloudflare
    # in front of alastor caps each request body at 100 MB, so one upload
    # through the public hostname cannot be larger than that.
    storage.maxVolumes = 8;

    # Krater Compute (see the comment at the top). The label prefix must be
    # unique to this deployment on the Vast account.
    compute.enable = false;
    compute.labelPrefix = "krater-staging-";
    # compute.vastKeyFile = config.age.secrets.krater-staging-vast-key.path;
    # projectSecretsKeyFile = config.age.secrets.krater-staging-project-secrets-key.path;

    # Cloudflare, Traefik on alastor and nginx on weft (see trustedProxyCount).
    extraEnv = {
      KRATER_TRUSTED_PROXY_COUNT = trustedProxyCount;
      KRATER_STAGING = "true";
      # Krater sends its events to Quilt only when this is set. Leave it
      # empty, or set it to Quilt staging. Never set it to production Quilt:
      # staging events would land in the real books. Events wait in Krater's
      # quilt_outbox table until it is set.
      KRATER_QUILT_URL = "";
    };

    # weft has no MagicDNS. KRATER_DATABASE_URL names hem by its tailnet name
    # (bin/new-krater-secrets staging). If hem joins the tailnet again, its
    # address changes: update it here and the pw-hem alias in
    # jaspermayone/infra tailscale/policy.hujson.
    extraHosts."hem.wildebeest-stargazer.ts.net" = "100.67.124.123";

    weave = {
      # Exactly the `issuer` in Weave staging's discovery document.
      issuer = stagingWeaveIssuer;
      clientId = stagingWeaveClientId;
      # The `krater` CLI's public Weave app (Krater's docs/compute/cli.md).
      # Empty keeps the CLI's API off.
      cliClientId = "";
    };

    # CI (krater repo, .github/workflows/deploy.yml) joins the tailnet as
    # tag:ci-krater and SSHes as krater-deploy to sshd on 2222 (Tailscale SSH
    # on 22 does not take keys). It deploys each main commit that passes CI.
    # Private key is the KRATER_DEPLOY_SSH_KEY repo secret.
    deployAuthorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKC+mqvF2BF2QkxeRlf5LSOmtw9Mke9JBUVu8P68h0/B github-actions-krater-deploy"
    ];

    # alastor's Traefik routes here (nixosModules.edge-alastor), so no Traefik
    # on weft.
    traefik.enable = false;
  };

  patchwork.services.krater-production = {
    enable = prodEnable;
    environmentFile = "/run/agenix/krater-env";

    # Fallback build; deploys write /var/lib/krater-prod/source-rev instead.
    rev = "b081a132fe1e6c2b8d998f45a65e507745052300";

    domain = "krater.patchworklabs.org";
    storage.domain = "krater-storage.patchworklabs.org";
    # At most 8 volumes of 1 GB, as for staging (see the disk note there).
    storage.maxVolumes = 8;

    # Compute stays off until Krater's paid checks pass. The prefix is set now
    # so that turning compute on cannot use staging's.
    compute.enable = false;
    compute.labelPrefix = "krater-prod-";

    extraEnv = {
      KRATER_TRUSTED_PROXY_COUNT = trustedProxyCount;
      # Empty until Quilt production takes Krater's events. Events wait in
      # Krater's quilt_outbox table until it is set.
      KRATER_QUILT_URL = "";
    };

    # weft has no MagicDNS. KRATER_DATABASE_URL in krater-env.age names skein
    # by its tailnet name (bin/new-krater-secrets production). Keep this in
    # step with the pw-skein alias in jaspermayone/infra tailscale/policy.hujson.
    extraHosts."skein.wildebeest-stargazer.ts.net" = "100.109.223.51";

    weave = {
      issuer = productionWeaveIssuer;
      clientId = productionWeaveClientId;
      cliClientId = "";
    };

    # No CI deploy for production yet: it gets its own key and user
    # (krater-prod-deploy) when it goes on.
    deployAuthorizedKeys = [ ];
    traefik.enable = false;
  };
}
