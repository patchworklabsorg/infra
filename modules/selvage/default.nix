# modules/selvage/default.nix
# Selvage: the Patchwork Labs Slack bot (Rails 8.1 API app, GoodJob). Two
# Docker containers from one image: web and worker. Exported by this flake as
# nixosModules.selvage; the host that runs it imports hosts/twill/selvage.nix,
# which sets the instance options below. Same shape as modules/stash, with
# production only.
#
# Databases: Selvage has no database of its own. It uses two central
# databases, and in each one the role `selvage` owns the schema `selvage`
# (hosts/central-db-schema.nix):
#   CENTRAL_DATABASE_URL     patchwork_central on skein (general data, polls,
#                            GoodJob; reads people.*)
#   RESTRICTED_DATABASE_URL  patchwork_central_restricted on seam
#                            (moderation and reports)
# The env file holds both URLs, passwords included:
#   postgres://selvage:<pw>@skein.wildebeest-stargazer.ts.net:5432/patchwork_central?sslmode=disable
#   postgres://selvage:<pw>@seam.wildebeest-stargazer.ts.net:5432/patchwork_central_restricted?sslmode=disable
# The passwords must be the ones in secrets/central-prod-selvage.age (skein)
# and secrets/restricted-prod-selvage.age (seam). The database hosts have no
# server TLS yet (modules/central-db); Tailscale encrypts the path, hence
# sslmode=disable.
#
# The role has no CREATE on either database, so the app must not run CREATE
# SCHEMA or enable_extension. The web container migrates both databases with
# the image's entrypoint before the server starts (`db:migrate`, as Stash
# does). The worker never migrates.
#
# Network: both containers use the host network (`--network host`), as Stash
# and Quilt do, so the tailnet names in the env file resolve through the
# host's /etc/hosts. The web server binds 127.0.0.1:<port>, and nginx on the
# host proxies to it.
#
# Units:
#   selvage-web     pulls the image, runs `./bin/rails server`. The image's
#                   entrypoint migrates before the server starts.
#   selvage-worker  `bundle exec good_job start`. Waits for GET /up on the
#                   web server (so the migrations ran), and restarts on
#                   failure until the schema is there. partOf selvage-web, so
#                   `systemctl restart selvage-web` moves both to a new image.
#
# Image: `image` is a full ref. The default tag `main` follows the newest push
# to main. Pin it to `ghcr.io/patchworklabsorg/selvage:<sha>` for a known
# build. The repo is private, so its package may be private too: set
# `registryCredentialsFile` to a token with read:packages, as Quilt does.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  cfg = config.patchwork.services.selvage;
  name = "selvage";

  # `--env 'KEY=value'` arguments for extraEnv. Each line ends with the
  # two-space indent the next docker argument expects.
  envArgs = lib.concatStrings (
    lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"} \\\n  ") cfg.extraEnv
  );

  # Log in to ghcr.io (when a token is set) and pull the image.
  pull = pkgs.writeShellScript "${name}-pull" ''
    set -e
    ${lib.optionalString (cfg.registryCredentialsFile != null) ''
      ${dockerBin} login ghcr.io \
        --username ${lib.escapeShellArg cfg.registryUsername} \
        --password-stdin < ${lib.escapeShellArg cfg.registryCredentialsFile}
    ''}
    ${dockerBin} pull ${lib.escapeShellArg cfg.image}
  '';

  common = unit: {
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    # Until the env file decrypts on this host (its key must be a recipient),
    # the units do not start, instead of restarting and pulling every 10 s.
    unitConfig.ConditionPathExists = cfg.environmentFile;
    # The worker restarts until the schema exists. Never stop retrying.
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "simple";
      TimeoutStartSec = "10min";
      ExecStop = "${dockerBin} stop ${name}-${unit}";
      Restart = "on-failure";
      RestartSec = "10s";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "${name}-${unit}";
    };
  };

  run = unit: ''
    ${dockerBin} run \
      --name ${name}-${unit} \
      --network host \
      --env-file ${lib.escapeShellArg cfg.environmentFile} \
      --env RAILS_ENV=production \
      ${envArgs}--restart no \
      ${lib.escapeShellArg cfg.image}'';
in
{
  options.patchwork.services.selvage = {
    enable = lib.mkEnableOption "Selvage, the Patchwork Labs Slack bot";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3009;
      description = "Loopback port the web server binds to. The host's reverse proxy proxies to it.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/patchworklabsorg/selvage:main";
      example = "ghcr.io/patchworklabsorg/selvage:0123abc";
      description = ''
        Image ref for web and worker. Pin it to a commit sha for a known build.
        Each start of selvage-web pulls it again.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/agenix/selvage-env";
      description = ''
        Path on the host of the env file (an agenix secret): CENTRAL_DATABASE_URL,
        RESTRICTED_DATABASE_URL, SECRET_KEY_BASE, SLACK_SIGNING_SECRET,
        SLACK_BOT_TOKEN, SLACK_ADMIN_TOKEN, SLACK_BROWSER_TOKEN,
        SLACK_BROWSER_COOKIE, WEAVE_ISSUER, WEAVE_CLIENT_ID,
        WEAVE_CLIENT_SECRET, SELVAGE_AUDIT_CHANNEL. A string, not a path, so
        that the host can name it before the secret exists.
      '';
    };

    registryCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File with a GitHub token that has read:packages, for a private image.
        Null: pull without a login (a public package).
      '';
    };

    registryUsername = lib.mkOption {
      type = lib.types.str;
      default = "pwlbot";
      description = "GitHub user that owns the token in registryCredentialsFile.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        RAILS_LOG_LEVEL = "debug";
      };
      description = ''
        Extra container env for web and worker. It overrides the env file, so
        do not put a value here that you want to change in the env file.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ── Web (Rails) ─────────────────────────────────────────────────────────
    systemd.services."${name}-web" = lib.recursiveUpdate (common "web") {
      description = "Selvage web";
      serviceConfig = {
        ExecStartPre = [
          pull
          "-${dockerBin} stop ${name}-web"
          "-${dockerBin} rm ${name}-web"
        ];
        # Same command as the image's CMD, on the loopback port. The
        # entrypoint matches `./bin/rails server` and migrates first.
        ExecStart = pkgs.writeShellScript "${name}-web-start" ''
          exec ${run "web"} \
            ./bin/rails server -b 127.0.0.1 -p ${toString cfg.port}
        '';
      };
    };

    # ── Worker (GoodJob) ────────────────────────────────────────────────────
    # Runs the jobs and the GoodJob cron. It never migrates, so it waits for
    # the web server, which migrates before it answers /up. One worker only.
    systemd.services."${name}-worker" = lib.recursiveUpdate (common "worker") {
      description = "Selvage worker";
      after = [
        "docker.service"
        "${name}-web.service"
      ];
      partOf = [ "${name}-web.service" ];
      serviceConfig = {
        ExecStartPre = [
          pull
          "-${dockerBin} stop ${name}-worker"
          "-${dockerBin} rm ${name}-worker"
          (pkgs.writeShellScript "${name}-wait-for-web" ''
            echo "Waiting for the web server (migrations)..."
            until ${pkgs.curl}/bin/curl -fsS -o /dev/null \
                http://127.0.0.1:${toString cfg.port}/up; do
              sleep 5
            done
          '')
        ];
        ExecStart = pkgs.writeShellScript "${name}-worker-start" ''
          exec ${run "worker"} \
            bundle exec good_job start
        '';
      };
    };
  };
}
