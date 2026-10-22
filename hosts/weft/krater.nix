# Krater on weft: the instance settings and the agenix secrets. nginx on weft
# (./configuration.nix) fronts the two ports, and alastor routes the public
# names here over the tailnet (nixosModules.edge-alastor).
#
# Network: the containers are on the `krater` bridge network. weft reaches
# skein.wildebeest-stargazer.ts.net:5432 (patchwork_central) over the tailnet,
# through the tag:patchwork-krater grant in jaspermayone/infra
# tailscale/policy.hujson. weft has no MagicDNS, so `extraHosts` gives the
# containers skein's tailnet address.
#
# Before Krater runs:
#   - DNS for the two hostnames below, proxied to alastor (patchworklabsorg/dns)
#   - Krater's Weave app and roles; fill in `weaveClientId` below. Krater stays
#     off until it is set, so weft builds and deploys without it.
#   - secrets/krater-env.age (jsp + weft) and secrets/central-prod-krater.age
#     (jsp + skein), from bin/new-krater-secrets, and skein deployed with
#     Krater's role and password
# The full checklist is in Krater's docs/dev/production.md.
#
# Krater Compute stays off (KRATER_COMPUTE_MODE=off) until Krater's paid checks
# pass (its docs/compute/README.md). Turning it on: rotate the Vast key, put it
# in secrets/krater-vast-key.age, uncomment the krater-vast-key secret below,
# and set compute.enable and compute.vastKeyFile.
#
# Project secrets (a member's HF_TOKEN for their jobs) need
# secrets/krater-project-secrets-key.age: one Fernet key per line, newest
# first. Make one with
#   python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# Back it up with the other agenix secrets: losing it loses every stored
# project secret.
{ config, ... }:
let
  # Client id of Krater's Weave app (redirect URI
  # https://krater.patchworklabs.org/auth/callback). Not secret. Empty keeps
  # Krater off.
  weaveClientId = "";
  enable = weaveClientId != "";
in
{
  imports = [ ../../modules/krater ];

  # Recipients are in ../../secrets/secrets.nix (jsp + weft's host key).
  age.secrets = {
    krater-env = {
      file = ../../secrets/krater-env.age;
      mode = "400";
    };
    # krater-project-secrets-key = {
    #   file = ../../secrets/krater-project-secrets-key.age;
    #   mode = "400";
    # };
    # krater-vast-key = {
    #   file = ../../secrets/krater-vast-key.age;
    #   mode = "400";
    # };
  };

  patchwork.services.krater = {
    inherit enable;
    environmentFile = config.age.secrets.krater-env.path;

    # Fallback build; deploys write /var/lib/krater/source-rev instead.
    rev = "16de89ada091eb27bf137f5f557a4ca59ac4ae30";

    # Proposed names. One level under patchworklabs.org: the records are
    # proxied through Cloudflare, whose edge certificate covers only one
    # subdomain level. Added by a PR to patchworklabsorg/dns, like weave's.
    domain = "krater.patchworklabs.org";
    storage.domain = "krater-storage.patchworklabs.org";

    # Krater Compute (see the comment at the top). The label prefix must be
    # unique to this deployment on the Vast account.
    compute.enable = false;
    # compute.vastKeyFile = config.age.secrets.krater-vast-key.path;
    # compute.labelPrefix = "krater-prod-";
    # projectSecretsKeyFile = config.age.secrets.krater-project-secrets-key.path;

    # Proxies that append to X-Forwarded-For: Traefik on alastor and nginx
    # here. nginx sets the client address from alastor's header
    # (./configuration.nix), and Cloudflare is in front of alastor. Check this
    # against a real request before relying on per-client rate limits.
    extraEnv.KRATER_TRUSTED_PROXY_COUNT = "2";

    # weft has no MagicDNS. KRATER_DATABASE_URL names skein by its tailnet
    # name (bin/new-krater-secrets). If skein joins the tailnet again, its
    # address changes: update it here and the pw-skein alias in
    # jaspermayone/infra tailscale/policy.hujson.
    extraHosts."skein.wildebeest-stargazer.ts.net" = "100.109.223.51";

    weave = {
      # Exactly the `issuer` in Weave's discovery document.
      issuer = "https://weave.patchworklabs.org";
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
