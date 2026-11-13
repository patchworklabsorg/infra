# modules/selvage/default.nix
# Selvage: the Patchwork Labs Slack bot (Rails 8.1 API app, GoodJob). Two
# Docker containers from one image: web and worker. Exported by this flake as
# nixosModules.selvage; the host that runs it imports hosts/twill/selvage.nix,
# which sets the instance options below. Same shape as modules/stash.
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
# SCHEMA or enable_extension. selvage-web runs `./bin/rails db:migrate` (both
# databases) in a one-off container before the server starts, so the
# migration does not depend on how the image's entrypoint matches its
# arguments. The worker never migrates.
#
# Required keys: the units refuse to start while a key in `requiredEnv` is
# missing or empty in the env file. An empty SLACK_SIGNING_SECRET would let
# anyone sign a Slack request with the empty key.
#
# Network: both containers use the host network (`--network host`), as Stash
# and Quilt do, so the tailnet names in the env file resolve through the
# host's /etc/hosts. The web server binds 127.0.0.1:<port>, and nginx on the
# host proxies to it.
#
# Units:
#   selvage-web     pulls the image, runs `./bin/rails db:migrate`, then
#                   `./bin/rails server`.
#   selvage-worker  `bundle exec good_job start`. Waits for GET /up on the
#                   web server (so the migrations ran), then runs the image
#                   that the web container runs, not a new pull, so it never
#                   runs code newer than the schema. partOf selvage-web, so
#                   `systemctl restart selvage-web` moves both to a new image.
#
# Image: `image` is a full ref. The default tag `main` follows the newest push
# to main. Pin it to `ghcr.io/patchworklabsorg/selvage:<sha>` for a known
# build. The repo is private, so its package may be private too: set
# `registryCredentialsFile` to a token with read:packages, as Quilt does.
#
# Staging (optional, `staging.enable`) is a second, separate instance from the
# same `mkInstance` function below: units and containers selvage-staging-web
# and selvage-staging-worker, its own port, image, env file and extraEnv, with
# RAILS_ENV=staging. It serves the staging Slack workspace through its own
# Slack app. Its databases are patchwork_central on hem:5432 and
# patchwork_central_restricted on hem:5433 (the staging clusters). The
# registry login and `requiredEnv` are shared with production. The staging
# containers get a Docker memory limit (`staging.memory`), so staging cannot
# take the memory that production needs.
#
# The production units must stay byte-identical when staging is added or
# changed. Keep every production name and script name in `mkInstance` derived
# from name = "selvage", and keep an empty `extraEnv` and the production
# `dockerArgs` free of characters.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  cfg = config.patchwork.services.selvage;

  # `--env 'KEY=value'` arguments for an instance's extraEnv. Each line ends
  # with the two-space indent the next docker argument expects. An empty
  # attrset renders "", which keeps the production units identical.
  envArgs =
    env:
    lib.concatStrings (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"} \\\n  ") env);

  # Every unit, container and script name of one Selvage instance comes from
  # `name`. Production is name = "selvage".
  #   name             unit, container and script prefix
  #   label            human prefix for unit descriptions ("Selvage")
  #   railsEnv         RAILS_ENV for every container
  #   port             loopback port of the web server
  #   image            image ref, pulled on each start of the web unit
  #   environmentFile  path of the agenix env file on the host
  #   envSecret        the env file's name in secrets/, for the error message
  #   extraEnv         extra container env; it overrides the env file
  #   dockerArgs       extra `docker run` arguments for every container, each
  #                    line ending as in envArgs. "" for production.
  mkInstance =
    {
      name,
      label,
      railsEnv,
      port,
      image,
      environmentFile,
      envSecret,
      extraEnv,
      dockerArgs,
    }:
    let
      envArgs' = envArgs extraEnv;

      # Log in to ghcr.io (when a token is set) and pull the image.
      pull = pkgs.writeShellScript "${name}-pull" ''
        set -e
        ${lib.optionalString (cfg.registryCredentialsFile != null) ''
          ${dockerBin} login ghcr.io \
            --username ${lib.escapeShellArg cfg.registryUsername} \
            --password-stdin < ${lib.escapeShellArg cfg.registryCredentialsFile}
        ''}
        ${dockerBin} pull ${lib.escapeShellArg image}
      '';

      # Stops the start when a required key is missing or empty in the env file.
      checkEnv = pkgs.writeShellScript "${name}-check-env" ''
        set -eu
        missing=""
        for key in ${lib.escapeShellArgs cfg.requiredEnv}; do
          if ! ${pkgs.gnugrep}/bin/grep -Eq "^$key=.+" ${lib.escapeShellArg environmentFile}; then
            missing="$missing $key"
          fi
        done
        if [ -n "$missing" ]; then
          echo "Empty or missing in ${environmentFile}:$missing" >&2
          echo "Set them with bin/set-env-secret ${envSecret}$missing" >&2
          exit 1
        fi
      '';

      common = unit: {
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        # Until the env file decrypts on this host (its key must be a recipient),
        # the units do not start, instead of restarting and pulling every 10 s.
        unitConfig.ConditionPathExists = environmentFile;
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

      # `image` is an argument: the worker runs the web container's image ID.
      run = unit: image: ''
        ${dockerBin} run \
          --name ${name}-${unit} \
          --network host \
          --env-file ${lib.escapeShellArg environmentFile} \
          --env RAILS_ENV=${railsEnv} \
          ${envArgs'}${dockerArgs}--restart no \
          ${image}'';
    in
    {
      # ── Web (Rails) ───────────────────────────────────────────────────────
      systemd.services."${name}-web" = lib.recursiveUpdate (common "web") {
        description = "${label} web";
        serviceConfig = {
          ExecStartPre = [
            checkEnv
            pull
            "-${dockerBin} stop ${name}-web"
            "-${dockerBin} rm ${name}-web"
            "-${dockerBin} rm -f ${name}-migrate"
            # Both databases. The role cannot CREATE, so never db:prepare.
            (pkgs.writeShellScript "${name}-migrate" ''
              exec ${dockerBin} run --rm \
                --name ${name}-migrate \
                --network host \
                --env-file ${lib.escapeShellArg environmentFile} \
                --env RAILS_ENV=${railsEnv} \
                ${envArgs'}${dockerArgs}--entrypoint "" \
                ${lib.escapeShellArg image} \
                ./bin/rails db:migrate
            '')
          ];
          # Same command as the image's CMD, on the loopback port.
          ExecStart = pkgs.writeShellScript "${name}-web-start" ''
            exec ${run "web" (lib.escapeShellArg image)} \
              ./bin/rails server -b 127.0.0.1 -p ${toString port}
          '';
        };
      };

      # ── Worker (GoodJob) ──────────────────────────────────────────────────
      # Runs the jobs and the GoodJob cron. It never migrates, so it waits for
      # the web server, which migrates before it answers /up. One worker only.
      systemd.services."${name}-worker" = lib.recursiveUpdate (common "worker") {
        description = "${label} worker";
        after = [
          "docker.service"
          "${name}-web.service"
        ];
        partOf = [ "${name}-web.service" ];
        serviceConfig = {
          ExecStartPre = [
            checkEnv
            "-${dockerBin} stop ${name}-worker"
            "-${dockerBin} rm ${name}-worker"
            (pkgs.writeShellScript "${name}-wait-for-web" ''
              echo "Waiting for the web server (migrations)..."
              until ${pkgs.curl}/bin/curl -fsS -o /dev/null \
                  http://127.0.0.1:${toString port}/up; do
                sleep 5
              done
            '')
          ];
          # The image ID of the running web container, so web and worker run
          # the same build even when `main` moved since the web unit started.
          ExecStart = pkgs.writeShellScript "${name}-worker-start" ''
            set -e
            image="$(${dockerBin} inspect -f '{{.Image}}' ${name}-web)"
            exec ${run "worker" "\"$image\""} \
              bundle exec good_job start
          '';
        };
      };
    };
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

    requiredEnv = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Z][A-Z0-9_]*");
      default = [
        "CENTRAL_DATABASE_URL"
        "RESTRICTED_DATABASE_URL"
        "SECRET_KEY_BASE"
        "SLACK_SIGNING_SECRET"
        "SLACK_BOT_TOKEN"
      ];
      description = ''
        Keys that must be set and not empty in the env file. The units do not
        start without them.
      '';
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

    staging = {
      enable = lib.mkEnableOption ''
        a Selvage staging instance (selvage-staging-web and
        selvage-staging-worker, RAILS_ENV=staging, own port, image and env
        file) alongside production
      '';

      port = lib.mkOption {
        type = lib.types.port;
        default = 3010;
        description = "Loopback port the staging web server binds to.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/patchworklabsorg/selvage:main";
        example = "ghcr.io/patchworklabsorg/selvage:0123abc";
        description = ''
          Image ref for the staging web and worker. Each start of
          selvage-staging-web pulls it again. The image must have the
          `staging` Rails environment (config/environments/staging.rb).
        '';
      };

      environmentFile = lib.mkOption {
        type = lib.types.str;
        example = "/run/agenix/selvage-staging-env";
        description = ''
          Path on the host of the staging env file (an agenix secret). Same
          keys as `environmentFile`, with staging values: the databases on
          hem:5432 and hem:5433, the staging Slack app's tokens, and a Weave
          staging client.
        '';
      };

      extraEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          WEAVE_ISSUER = "https://weave-staging.patchworklabs.org";
        };
        description = ''
          Extra container env for the staging web and worker. It overrides the
          staging env file. RAILS_ENV=staging is always set.
        '';
      };

      memory = lib.mkOption {
        type = lib.types.strMatching "[0-9]+[kmg]";
        default = "512m";
        description = ''
          Docker memory limit of each staging container (web, worker and the
          one-off migration), with no swap. It keeps staging from taking the
          memory that production needs on a small host.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ── Production ──────────────────────────────────────────────────────────
      (mkInstance {
        name = "selvage";
        label = "Selvage";
        railsEnv = "production";
        envSecret = "selvage-env.age";
        dockerArgs = "";
        inherit (cfg)
          port
          image
          environmentFile
          extraEnv
          ;
      })

      # ── Staging ─────────────────────────────────────────────────────────────
      (lib.mkIf cfg.staging.enable (mkInstance {
        name = "selvage-staging";
        label = "Selvage staging";
        railsEnv = "staging";
        envSecret = "selvage-staging-env.age";
        dockerArgs = "--memory ${cfg.staging.memory} --memory-swap ${cfg.staging.memory} \\\n  ";
        inherit (cfg.staging)
          port
          image
          environmentFile
          extraEnv
          ;
      }))
    ]
  );
}
