# Krater on alastor. Exported as nixosModules.krater-alastor.
#
# alastor is jaspermayone's VPS and is built from jaspermayone/infra, which
# imports this module through its `patchwork-infra` flake input, the same way
# as nixosModules.weave-alastor.
#
# What the importing host must provide:
#   - the agenix NixOS module (`age.*` options)
#   - Docker, with the buildx plugin (krater-build uses BuildKit)
#   - Traefik with the file provider on /etc/traefik/conf.d and a `cloudflare`
#     cert resolver and `hsts` middleware (infra's modules/traefik)
#   - loopback ports 3010-3011 free (see the module's port options)
#
# Before the first deploy:
#   - DNS for the two hostnames below (patchworklabsorg/dns)
#   - Krater's Weave app and roles; fill in the client id below
#   - secrets/krater-env.age
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
{
  imports = [ ../../modules/krater ];

  # Recipients are in ../../secrets/secrets.nix (jsp + alastor's host key).
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
    enable = true;
    environmentFile = config.age.secrets.krater-env.path;

    # Fallback build; deploys write /var/lib/krater/source-rev instead.
    rev = "4f130ca51137aa8d7f65e408e04ab8f589fe9eae";

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

    # With Cloudflare in front of Traefik, the client's address is not the
    # last X-Forwarded-For hop the module's default (1) assumes. Set this to
    # the number of proxies that append to X-Forwarded-For once Traefik's
    # forwardedHeaders.trustedIPs are known, or rate limits key on
    # Cloudflare's edge addresses.
    # extraEnv.KRATER_TRUSTED_PROXY_COUNT = "2";

    weave = {
      # Exactly the `issuer` in Weave's discovery document.
      issuer = "https://weave.patchworklabs.org";
      # Not secret, but only known once the app exists in Weave. The module
      # refuses to build while it is empty.
      clientId = "";
      # The `krater` CLI's public Weave app (Krater's docs/compute/cli.md).
      # Empty keeps the CLI's API off.
      cliClientId = "";
    };

    # CI (krater repo, .github/workflows/deploy.yml) SSHes as krater-deploy.
    # Add its public key here once the KRATER_DEPLOY_SSH_KEY secret exists.
    deployAuthorizedKeys = [ ];

    traefik.enable = true;
  };
}
