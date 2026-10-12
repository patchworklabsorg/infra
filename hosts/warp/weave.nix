# Weave on warp. Same settings as ../alastor/weave.nix, except that the
# Traefik routes live on alastor (nixosModules.edge-alastor) and nginx on warp
# fronts the ports. Delete ../alastor/weave.nix once Weave runs here.
#
# Before the first deploy: add warp's host key to weave-env.age and
# weave-staging-env.age in secrets/secrets.nix and run `agenix -r`.
{ config, ... }:
{
  imports = [ ../../modules/weave ];

  age.secrets = {
    weave-env = {
      file = ../../secrets/weave-env.age;
      mode = "400";
    };
    weave-staging-env = {
      file = ../../secrets/weave-staging-env.age;
      mode = "400";
    };
  };

  patchwork.services.weave = {
    enable = true;
    environmentFile = config.age.secrets.weave-env.path;
    extraEnv.MAIL_DOMAIN = "weave.patchworklabs.org";
    # The weave repo's deploy workflow must point at warp instead of alastor.
    deployAuthorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlQambjmi/gstrJ6CH/ZnMbuqkp+ad5ckfkx5STdKU6 github-actions-weave-deploy"
    ];
    staging = {
      enable = true;
      environmentFile = config.age.secrets.weave-staging-env.path;
      extraEnv = {
        APP_HOST = "weave-staging.patchworklabs.org";
        MAIL_DOMAIN = "sandbox.patchworklabs.org";
      };
    };
  };
}
