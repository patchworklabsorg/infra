# agenix recipients for the secrets in this directory.
#
#   cd secrets && agenix -e <name>.age   # create or edit
#   cd secrets && agenix -r              # re-key after changing a recipient list
#
# The .age files are public in this repo. Only the listed keys can decrypt
# them. Re-keying needs a machine that holds one of the current keys.
let
  # Admins
  jsp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHm7lo7umraewipgQu1Pifmoo/V8jYGDHjBTmt+7SOCe me@jaspermayone.com";

  # Hosts (/etc/ssh/ssh_host_ed25519_key.pub)
  alastor = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFwkC1CiWpLB10NNVaJwu4LSyiL0wM7ExI1VoKqIsgeG root@alastor-vnic";
  skein = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMyAEZuxPllSL4clx7Si8tvMfdSLv+v4/z19nz75oHtl";
  seam = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIpDr8Ilx3Nh4VOgDK4y54OTbt/ax2bExU+fv+aWSAB6";
  # warp, hem: add each key after its install, then add the host to the
  # files it needs and run `agenix -r`.
  #
  # Central DB passwords, one file per app and environment, password only:
  #   central-prod-<app>.age        recipients: jsp, skein
  #   restricted-prod-<app>.age     recipients: jsp, seam
  #   central-staging-<app>.age     recipients: jsp, hem
  #   restricted-staging-<app>.age  recipients: jsp, hem
  # The app host that connects needs the same file, so add it as a recipient.
  #
  # ad-join.age: the svc-lnx-join password only (vault key
  # vault_ad_join_password_patchwork). Recipients: jsp and every host.
  # modules/ad-join uses it when the file exists.
  #
  # weave-ldap.age: the svc-weave-ldap password only (ad/README.md, Weave).
  # Recipients: jsp and the host that runs Weave (alastor now, warp after
  # the move). To rotate: set a new password in AD, then `agenix -e`.
in
{
  # Weave (Patchwork IDP) runtime env. Must contain:
  #   RAILS_MASTER_KEY=...   (decrypts config/credentials)
  #   POSTGRES_PASSWORD=...  (Rails DB password + postgres container init)
  "weave-env.age".publicKeys = [
    jsp
    alastor
  ];

  # svc-weave-ldap password (no newline). Set in AD on 2026-10-20.
  # Weave reads it from AD_BIND_PASSWORD_FILE (patchworklabsorg/weave#218).
  # Not wired into modules/weave yet. Give the container a copy outside
  # /run/agenix, as modules/central-db does.
  "weave-ldap.age".publicKeys = [
    jsp
    alastor
  ];

  # Weave staging (weave-staging.patchworklabs.org) runtime env. Same keys as
  # weave-env.age:
  #   RAILS_MASTER_KEY=...   (the staging credentials key, not production's)
  #   POSTGRES_PASSWORD=...  (staging Rails DB password + postgres container init)
  "weave-staging-env.age".publicKeys = [
    jsp
    alastor
  ];

  # Quilt (quilt.patchworklabs.org on alastor) runtime env. Must contain the
  # variables in docs/deploy.md of patchworklabsorg/quilt:
  #   RESTRICTED_DATABASE_URL=postgres://quilt:<password>@seam.wildebeest-stargazer.ts.net:5432/patchwork_central_restricted?sslmode=disable
  #     (<password> is the value in restricted-prod-quilt.age)
  #   SECRET_KEY_BASE=...
  #   WEAVE_ISSUER=...  WEAVE_CLIENT_ID=...  WEAVE_CLIENT_SECRET=...
  #   MERCURY_API_TOKEN=...  (read-only token)
  #   MERCURY_API_BASE=https://api.mercury.com/api/v1/
  #   MERCURY_WRITE_TOKEN=   (may be blank while QUILT_TOPUPS=off)
  #   QUILT_TOPUPS=off
  "quilt-env.age".publicKeys = [
    jsp
    alastor
  ];

  # Quilt staging (quilt-staging.patchworklabs.org on alastor, RAILS_ENV=staging)
  # runtime env. bin/new-quilt-staging-secrets writes it. Same variables as
  # quilt-env.age, with staging values:
  #   RESTRICTED_DATABASE_URL=postgres://quilt:<password>@hem.wildebeest-stargazer.ts.net:5433/patchwork_central_restricted?sslmode=disable
  #     (<password> is the value in restricted-staging-quilt.age)
  #   SECRET_KEY_BASE=...    (its own, not production's)
  #   WEAVE_CLIENT_ID=...  WEAVE_CLIENT_SECRET=...  (a Weave staging app)
  #   MERCURY_API_TOKEN=...  (a Mercury SANDBOX read-only token)
  #   MERCURY_WRITE_TOKEN=   (a sandbox token; may be blank while QUILT_TOPUPS=off)
  #   QUILT_TOPUPS=off
  # MERCURY_API_BASE (the sandbox) and WEAVE_ISSUER (Weave staging) are set in
  # hosts/alastor/quilt.nix and override this file.
  "quilt-staging-env.age".publicKeys = [
    jsp
    alastor
  ];

  # GitHub classic PAT with read:packages only, for ghcr.io/patchworklabsorg/quilt
  # (a private package). The token only, no newline needed.
  "quilt-ghcr-token.age".publicKeys = [
    jsp
    alastor
  ];

  # Quilt's role password in patchwork_central_restricted (seam). Password
  # only. alastor does not get this file: the same password is in
  # quilt-env.age.
  "restricted-prod-quilt.age".publicKeys = [
    jsp
    seam
  ];

  # Quilt's role password in patchwork_central_restricted on hem:5433 (the
  # restricted staging cluster). Password only. hem decrypts it into the
  # restricted-staging container (hosts/hem/configuration.nix). alastor does
  # not get this file: the same password is in quilt-staging-env.age.
  # TODO: add hem after its install, then `agenix -r`.
  "restricted-staging-quilt.age".publicKeys = [ jsp ];

  # svc-lnx-join password only (modules/ad-join, ansible/sync-join-password.yml).
  # Add each lab host key after its install, then `agenix -r`.
  "ad-join.age".publicKeys = [
    jsp
    skein
    seam
  ];
}
