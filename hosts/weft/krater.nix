# Krater staging on weft: the instance settings and the agenix secrets. nginx
# on weft (./configuration.nix) fronts the two ports, and alastor routes the
# public names here over the tailnet (nixosModules.edge-alastor). Krater has
# no production instance yet: only staging runs, on weft.
#
# Staging follows the Patchwork staging standard: its own database (the
# `krater` schema in patchwork_central on hem:5432), Weave staging for sign-in,
# and its own hostnames. Krater Compute stays off, so no Vast account is used.
# Krater itself has no staging mode (KRATER_ENV is `production` here, which
# only turns on Krater's production checks). The construction border and the
# STAGING label are a change in the Krater app.
#
# Network: the containers are on the `krater` bridge network. weft reaches
# hem.wildebeest-stargazer.ts.net:5432 over the tailnet, through the
# tag:patchwork-krater grant in jaspermayone/infra tailscale/policy.hujson.
# weft has no MagicDNS, so `extraHosts` gives the containers hem's tailnet
# address.
#
# Before Krater staging runs (Krater stays off until the env file and the
# Weave client id both exist, so weft builds and deploys without them):
#   - secrets/krater-staging-env.age (jsp + weft) and
#     secrets/central-staging-krater.age (jsp + hem): run
#     `bin/new-krater-secrets staging`, then deploy hem so the krater role
#     gets its password
#   - Krater's app in Weave staging; fill in `weaveClientId` below, and the
#     client secret and the Slack values in krater-staging-env.age
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
{ lib, ... }:
let
  # Client id of Krater's app in Weave staging (redirect URI
  # https://krater-staging.patchworklabs.org/auth/callback). Not secret.
  weaveClientId = "";
  envFile = ../../secrets/krater-staging-env.age;
  enable = weaveClientId != "" && builtins.pathExists envFile;
in
{
  imports = [ ../../modules/krater ];

  # Recipients are in ../../secrets/secrets.nix (jsp + weft's host key).
  age.secrets = lib.mkIf (builtins.pathExists envFile) {
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
  };

  patchwork.services.krater = {
    inherit enable;
    # agenix's default path for the secret above.
    environmentFile = "/run/agenix/krater-staging-env";

    # Fallback build; deploys write /var/lib/krater/source-rev instead.
    rev = "16de89ada091eb27bf137f5f557a4ca59ac4ae30";

    # One level under patchworklabs.org: the records are proxied through
    # Cloudflare, whose edge certificate covers only one subdomain level.
    # Added by a PR to patchworklabsorg/dns, like weave-staging's.
    domain = "krater-staging.patchworklabs.org";
    storage.domain = "krater-staging-storage.patchworklabs.org";

    # Krater Compute (see the comment at the top). The label prefix must be
    # unique to this deployment on the Vast account.
    compute.enable = false;
    # compute.vastKeyFile = config.age.secrets.krater-staging-vast-key.path;
    # compute.labelPrefix = "krater-staging-";
    # projectSecretsKeyFile = config.age.secrets.krater-staging-project-secrets-key.path;

    # Proxies that append to X-Forwarded-For: Traefik on alastor and nginx
    # here. nginx sets the client address from alastor's header
    # (./configuration.nix), and Cloudflare is in front of alastor. Check this
    # against a real request before relying on per-client rate limits.
    extraEnv.KRATER_TRUSTED_PROXY_COUNT = "2";

    # weft has no MagicDNS. KRATER_DATABASE_URL names hem by its tailnet name
    # (bin/new-krater-secrets staging). If hem joins the tailnet again, its
    # address changes: update it here and the pw-hem alias in
    # jaspermayone/infra tailscale/policy.hujson.
    extraHosts."hem.wildebeest-stargazer.ts.net" = "100.67.124.123";

    weave = {
      # Exactly the `issuer` in Weave staging's discovery document.
      issuer = "https://weave-staging.patchworklabs.org";
      clientId = weaveClientId;
      # The `krater` CLI's public Weave app (Krater's docs/compute/cli.md).
      # Empty keeps the CLI's API off.
      cliClientId = "";
    };

    # CI (krater repo, .github/workflows/deploy.yml) SSHes as krater-deploy.
    # Add its public key here once the KRATER_DEPLOY_SSH_KEY secret exists.
    deployAuthorizedKeys = [ ];

    # alastor's Traefik routes here (nixosModules.edge-alastor), so no Traefik
    # on weft.
    traefik.enable = false;
  };
}
