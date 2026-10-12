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
# This release of Krater launches no machines (KRATER_COMPUTE_MODE=off).
# Krater Compute, its own Vast layer, adds the settings for renting in its own
# release (krater-vast-key.age comes back then, for Krater's worker).
{ config, ... }:
{
  imports = [ ../../modules/krater ];

  # Recipients are in ../../secrets/secrets.nix (jsp + alastor's host key).
  age.secrets = {
    krater-env = {
      file = ../../secrets/krater-env.age;
      mode = "400";
    };
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
    };

    # CI (krater repo, .github/workflows/deploy.yml) SSHes as krater-deploy.
    # Add its public key here once the KRATER_DEPLOY_SSH_KEY secret exists.
    deployAuthorizedKeys = [ ];

    traefik.enable = true;
  };
}
