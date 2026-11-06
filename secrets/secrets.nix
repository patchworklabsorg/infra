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
  warp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJoRstg6i9nq60YNVyKvlhsURUHnNGPXcR5eV6P6hmXH";
  hem = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHFHZ/2Q8x+Z9toPli2yQZpQ4e8dBMOqDAFyAFaxgsIE";
  batting = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEN68vw2ir+q4fMQV8WBJvH7WDG4D2uFjChwkkA93LJC";
  weft = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbzni2Be82ORFcHSPVr7OPpfs80Py04JtwyCKc4L28X";
  #
  # Central DB passwords, one file per app and environment, password only:
  #   central-prod-<app>.age        recipients: jsp, skein
  #   restricted-prod-<app>.age     recipients: jsp, seam
  #   central-staging-<app>.age     recipients: jsp, hem
  #   restricted-staging-<app>.age  recipients: jsp, hem
  # The app host that connects needs the same file, so add it as a recipient.
  #
  # ad-join.age: the svc-lnx-join password only (vault key
  # vault_ad_join_password_patchwork). Recipients: jsp and every lab host.
  # modules/ad-join uses it when the file exists.
  #
  # weave-ldap.age: the svc-weave-ldap password only (ad/README.md, Weave).
  # Recipients: jsp and alastor, the host that runs Weave. To rotate: set a new password in AD, then `agenix -e`.
in
{
  # Weave (Patchwork IDP) runtime env. Must contain:
  #   RAILS_MASTER_KEY=...       (decrypts config/credentials)
  #   POSTGRES_PASSWORD=...      (Rails DB password + postgres container init)
  #   GITHUB_CLIENT_ID=...       (production GitHub app, for linking GitHub
  #   GITHUB_CLIENT_SECRET=...    profiles, patchworklabsorg/weave#108)
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
  #   RAILS_MASTER_KEY=...       (the staging credentials key, not production's)
  #   POSTGRES_PASSWORD=...      (staging Rails DB password + postgres container init)
  #   GITHUB_CLIENT_ID=...       (the GitHub app shared by staging and local dev,
  #   GITHUB_CLIENT_SECRET=...    not production's)
  "weave-staging-env.age".publicKeys = [
    jsp
    alastor
  ];

  # Krater staging (Project Ganymede portal, krater-staging.patchworklabs.org
  # on weft) runtime env. The keys it must contain are listed at the top of
  # ../modules/krater/default.nix. KRATER_DATABASE_URL holds the password in
  # central-staging-krater.age. `bin/new-krater-secrets staging` writes both
  # files. KRATER_SLACK_BOT_TOKEN and
  # KRATER_SLACK_SIGNING_SECRET come from a separate Slack app in a test
  # workspace, never the real Patchwork workspace.
  "krater-staging-env.age".publicKeys = [
    jsp
    weft
  ];

  # Krater production (krater.patchworklabs.org on weft) runtime env. Same keys
  # as staging. KRATER_DATABASE_URL holds the password in
  # central-prod-krater.age (skein). `bin/new-krater-secrets production` writes
  # both files. Production is off until hosts/weft/krater-production.nix turns
  # it on. Its Slack values come from the real Patchwork Slack app.
  "krater-env.age".publicKeys = [
    jsp
    weft
  ];

  # Quilt (quilt.patchworklabs.org on batting) runtime env. Must contain the
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
    batting
  ];

  # Krater staging's role password in patchwork_central on hem (:5432).
  # Password only. weft does not get this file: the same password is in
  # krater-staging-env.age.
  "central-staging-krater.age".publicKeys = [
    jsp
    hem
  ];

  # Krater production's role password in patchwork_central on skein. Password
  # only. skein reads it only once hosts/weft/krater-production.nix moves
  # krater to `apps` (hosts/central-db-schema.nix). weft does not get this
  # file: the same password is in krater-env.age.
  "central-prod-krater.age".publicKeys = [
    jsp
    skein
  ];

  # The Vast.ai API key Krater staging's Compute rents with: the bare key,
  # nothing else in the file. Only Krater's worker reads it. Not used while
  # Krater's compute is off.
  "krater-staging-vast-key.age".publicKeys = [
    jsp
    weft
  ];

  # Krater staging's project-secrets keys: Fernet keys, one per line, newest
  # first. Only Krater's portal reads it. Losing it loses every stored
  # project secret.
  "krater-staging-project-secrets-key.age".publicKeys = [
    jsp
    weft
  ];

  # Production's Vast key and project-secrets keys, as for staging. Not
  # created yet: compute and project secrets are off in production too.
  "krater-vast-key.age".publicKeys = [
    jsp
    weft
  ];
  "krater-project-secrets-key.age".publicKeys = [
    jsp
    weft
  ];

  # Quilt staging (quilt-staging.patchworklabs.org on batting, RAILS_ENV=staging)
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
  # hosts/batting/quilt.nix and override this file.
  "quilt-staging-env.age".publicKeys = [
    jsp
    batting
  ];

  # GitHub classic PAT with read:packages only, for ghcr.io/patchworklabsorg/quilt
  # (a private package). The token only, no newline needed.
  "quilt-ghcr-token.age".publicKeys = [
    jsp
    batting
  ];

  # App role passwords in patchwork_central (skein). Password only. Add the
  # host that runs the app as a recipient when the app connects, and put the
  # same password in that app's env file.
  "central-prod-weave.age".publicKeys = [
    jsp
    skein
  ];
  "central-prod-selvage.age".publicKeys = [
    jsp
    skein
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
  # not get this file: the same password is in quilt-staging-env.age, so a
  # rotation must change both files.
  "restricted-staging-quilt.age".publicKeys = [
    jsp
    hem
  ];

  # App role passwords in patchwork_central on hem:5432 (the central staging
  # cluster). Password only. hem decrypts them into the central-staging
  # container. Add the host that runs the app when the app connects.
  "central-staging-weave.age".publicKeys = [
    jsp
    hem
  ];
  "central-staging-selvage.age".publicKeys = [
    jsp
    hem
  ];

  # svc-lnx-join password only (modules/ad-join, ansible/sync-join-password.yml).
  # Add each lab host key after its install, then `agenix -r`.
  "ad-join.age".publicKeys = [
    jsp
    skein
    seam
    warp
    hem
    batting
    weft
  ];
}
