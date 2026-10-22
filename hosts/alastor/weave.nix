# Weave on alastor. Exported as nixosModules.weave-alastor.
#
# alastor is jaspermayone's VPS and is built from jaspermayone/infra, which
# imports this module through its `patchwork-infra` flake input. Everything
# Patchwork-specific about the deployment lives here: the instance settings,
# the CI deploy key, the Traefik routes and the agenix secrets.
#
# What the importing host must provide:
#   - the agenix NixOS module (`age.*` options)
#   - Docker (the module runs its containers through it)
#   - Traefik with the file provider on /etc/traefik/conf.d and a `cloudflare`
#     cert resolver and `hsts` middleware (infra's modules/traefik)
#
# To change any of this: merge here, then in infra run
#   nix flake update patchwork-infra
# and deploy alastor.
{ config, ... }:
{
  imports = [ ../../modules/weave ];

  # Recipients are in ../../secrets/secrets.nix (jsp + alastor's host key).
  age.secrets = {
    weave-env = {
      file = ../../secrets/weave-env.age;
      mode = "400";
    };
    # Same two keys as weave-env, but RAILS_MASTER_KEY is the staging
    # credentials key and POSTGRES_PASSWORD is for the staging database.
    weave-staging-env = {
      file = ../../secrets/weave-staging-env.age;
      mode = "400";
    };
    # The svc-weave-ldap password, for Weave staging's AD sign-in
    # (../../ad/README.md, "Weave"). A real file in its own directory, not
    # the usual /run/agenix symlink: the staging containers mount the
    # directory, so a new password after `agenix -r` and a deploy is visible
    # with no container restart (Weave reads the file at each bind).
    weave-ldap = {
      file = ../../secrets/weave-ldap.age;
      path = "/run/weave-staging-ad/bind-password";
      symlink = false;
      mode = "400";
    };
  };

  patchwork.services.weave = {
    enable = true;
    environmentFile = config.age.secrets.weave-env.path;
    # Sender domain verified in Resend. The weave repo's lib/weave.rb reads it.
    extraEnv.MAIL_DOMAIN = "weave.patchworklabs.org";
    # CI (weave repo, .github/workflows/deploy.yml) SSHes as weave-deploy and runs
    # `sudo systemctl restart weave-web`. Private key is the WEAVE_DEPLOY_SSH_KEY
    # repo secret.
    deployAuthorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlQambjmi/gstrJ6CH/ZnMbuqkp+ad5ckfkx5STdKU6 github-actions-weave-deploy"
    ];

    traefik = {
      enable = true;
      hosts = [
        "weave.patchworklabs.org"
        "slack.patchworklabs.org"
      ];
    };

    # weave-staging.patchworklabs.org: weave-staging-* units on 127.0.0.1:3004.
    # Same weave-deploy user; CI restarts it with
    # `sudo systemctl restart weave-staging-web`.
    staging = {
      enable = true;
      environmentFile = config.age.secrets.weave-staging-env.path;
      hosts = [ "weave-staging.patchworklabs.org" ];
      extraEnv = {
        APP_HOST = "weave-staging.patchworklabs.org";
        # Sender domain verified in Resend; the staging Resend key only allows
        # this domain. Who receives staging mail is the weave repo's
        # `mail_allowlist` credential.
        MAIL_DOMAIN = "sandbox.patchworklabs.org";

        # AD as the password store (weave repo, docs/ACTIVE_DIRECTORY.md).
        # Staging only. Production stays off until the staging test plan
        # in that doc passes.
        AD_ENABLED = "true";
        # The account has no UPN, so use the DN.
        AD_BIND_DN = "CN=svc-weave-ldap,OU=Service-Accounts,OU=Patchwork,DC=patchwork,DC=internal";
        AD_BIND_PASSWORD_FILE = "/run/weave/ad/bind-password";
        AD_CA_FILE = "/run/weave/ad-ca.pem";
      };

      # alastor's DNS can not resolve patchwork.internal. The DCs are on the
      # tailnet (tag:patchwork-dc), and the tailnet policy lets alastor
      # (tag:ingress) reach them on tcp:636 only. The names must match the
      # DC certificates, so map them to the tailnet addresses. These change
      # only if a DC joins the tailnet again: check with `tailscale ip -4 loom`.
      extraHosts = {
        "loom.patchwork.internal" = "100.75.125.1";
        "spindle.patchwork.internal" = "100.108.7.59";
      };

      volumes = [
        "/run/weave-staging-ad:/run/weave/ad:ro"
        # The forest CA chain (issuing CA + root). Public. Written by
        # `ansible-playbook ad.yml -t ca-chain`; rerun after a CA renewal.
        "${../../ansible/files/pki/patchwork.internal-ca-chain.pem}:/run/weave/ad-ca.pem:ro"
      ];
    };
  };
}
