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
#   - loopback ports 3010-3012 free (see the module's port options)
#
# Before the first deploy:
#   - DNS for the three hostnames below (patchworklabsorg/dns)
#   - the two Weave apps and Krater's roles; fill in the client ids below
#   - secrets/krater-env.age and secrets/krater-vast-key.age
# The full checklist and the SkyPilot bootstrap are in Krater's
# docs/dev/production.md.
{ config, ... }:
{
  imports = [ ../../modules/krater ];

  # Recipients are in ../../secrets/secrets.nix (jsp + alastor's host key).
  age.secrets = {
    krater-env = {
      file = ../../secrets/krater-env.age;
      mode = "400";
    };
    krater-vast-key = {
      file = ../../secrets/krater-vast-key.age;
      mode = "400";
    };
  };

  patchwork.services.krater = {
    enable = true;
    environmentFile = config.age.secrets.krater-env.path;
    vastKeyFile = config.age.secrets.krater-vast-key.path;

    # Fallback build; deploys write /var/lib/krater/source-rev instead.
    rev = "4f130ca51137aa8d7f65e408e04ab8f589fe9eae";

    # Proposed names. One level under patchworklabs.org: the records are
    # proxied through Cloudflare, whose edge certificate covers only one
    # subdomain level. Added by a PR to patchworklabsorg/dns, like weave's.
    domain = "krater.patchworklabs.org";
    storage.domain = "krater-storage.patchworklabs.org";
    skypilot.domain = "krater-sky.patchworklabs.org";

    # With Cloudflare in front of Traefik, the client's address is not the
    # last X-Forwarded-For hop the module's default (1) assumes. Set this to
    # the number of proxies that append to X-Forwarded-For once Traefik's
    # forwardedHeaders.trustedIPs are known, or rate limits key on
    # Cloudflare's edge addresses.
    # extraEnv.KRATER_TRUSTED_PROXY_COUNT = "2";

    weave = {
      # Exactly the `issuer` in Weave's discovery document.
      issuer = "https://weave.patchworklabs.org";
      # Not secret, but only known once the apps exist in Weave. The module
      # refuses to build while these are empty.
      clientId = "";
      skypilotClientId = "";
    };

    # CI (krater repo, .github/workflows/deploy.yml) SSHes as krater-deploy.
    # Add its public key here once the KRATER_DEPLOY_SSH_KEY secret exists.
    deployAuthorizedKeys = [ ];

    traefik.enable = true;
  };
}
