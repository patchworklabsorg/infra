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

    domain = "krater.patchworklabs.org";
    storage.domain = "storage.krater.patchworklabs.org";
    skypilot.domain = "sky.krater.patchworklabs.org";

    weave = {
      issuer = "https://idp.patchworklabs.org";
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
