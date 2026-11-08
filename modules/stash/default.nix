# modules/stash/default.nix
# Stash: the Patchwork Labs archive (Rails). Two Docker containers from one
# image: web and worker. Exported by this flake as nixosModules.stash; the
# host that runs it imports hosts/hank/stash.nix, which sets the instance
# options below. Same shape as modules/quilt.
#
# The contract with the app is docs/deploy.md in patchworklabsorg/stash.
#
# Database: Stash has no database of its own. It connects only to
# patchwork_central (skein, prod) as the role `stash`, which owns the schema
# `stash` (hosts/central-db-schema.nix). The env file holds the full
# CENTRAL_DATABASE_URL, password included:
#   postgres://stash:<password>@skein.wildebeest-stargazer.ts.net:5432/patchwork_central?sslmode=disable
# The password must be the one in secrets/central-prod-stash.age, which skein
# sets on the role. skein has no server TLS yet (modules/central-db); Tailscale
# encrypts the path, hence sslmode=disable.
#
# Files: the artifacts (MHTML, PDFs, git bundles, videos) live on the host in
# `dataDir`, bind-mounted into both containers at the same path, with
# STASH_STORAGE_SERVICE=disk and STASH_STORAGE_PATH set to it. The web
# container serves them through signed URLs; the worker writes them. An
# S3-compatible bucket is a later option: set STASH_STORAGE_SERVICE=s3 and the
# S3_* variables in the env file, and leave dataDir unused.
#
# Network: both containers use the host network (`--network host`), as Quilt
# does, so the tailnet names in the env file resolve through the host's
# /etc/hosts. The web server binds 127.0.0.1:<port>, and nginx on the host
# proxies to it.
#
# The worker runs headless Chromium, git, yt-dlp, gallery-dl and LibreOffice
# inside the container. Chromium needs a large /dev/shm (`--shm-size`), and
# the worker gets a memory limit so a runaway capture cannot take the host.
#
# Units:
#   stash-web     pulls the image, runs `./bin/rails server`. The image's
#                 entrypoint runs `db:migrate` before the server starts.
#   stash-worker  `bundle exec good_job start`. Waits for GET /up on the web
#                 server (so the migrations ran), and restarts on failure
#                 until the schema is there. partOf stash-web, so
#                 `systemctl restart stash-web` moves both to a new image.
#
# Image: `image` is a full ref. The default tag `main` follows the newest push
# to main. Pin it to `ghcr.io/patchworklabsorg/stash:<sha>` for a known build.
# The package is public, so no registry login is needed.
#
# Staging (optional, `staging.enable`) is a second, separate instance from the
# same `mkInstance` function: units and containers stash-staging-web and
# stash-staging-worker, its own port, image, env file, data dir and extraEnv,
# with RAILS_ENV=staging (the construction border on every page). Its
# database is patchwork_central on hem:5432 (the central staging cluster).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  cfg = config.patchwork.services.stash;

  # `--env 'KEY=value'` arguments for an instance's extraEnv. Each line ends
  # with the two-space indent the next docker argument expects.
  envArgs =
    env:
    lib.concatStrings (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"} \\\n  ") env);

  # Every unit, container and script name of one Stash instance comes from
  # `name`. Production is name = "stash".
  mkInstance =
    {
      name,
      label,
      railsEnv,
      port,
      image,
      environmentFile,
      dataDir,
      extraEnv,
      workerMemory,
    }:
    let
      pull = pkgs.writeShellScript "${name}-pull" ''
        set -e
        ${dockerBin} pull ${lib.escapeShellArg image}
      '';

      common = unit: {
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        # The worker restarts until the schema exists. Never stop retrying.
        startLimitIntervalSec = 0;
        serviceConfig = {
          Type = "simple";
          # The image carries Chromium and LibreOffice: a new layer takes a while.
          TimeoutStartSec = "15min";
          ExecStop = "${dockerBin} stop ${name}-${unit}";
          Restart = "on-failure";
          RestartSec = "10s";
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "${name}-${unit}";
        };
      };

      # The data dir is owned by uid 1000, the `rails` user inside the image.
      prepareData = pkgs.writeShellScript "${name}-prepare-data" ''
        set -e
        mkdir -p ${lib.escapeShellArg dataDir}
        chown 1000:1000 ${lib.escapeShellArg dataDir}
        chmod 750 ${lib.escapeShellArg dataDir}
      '';

      run = unit: extraArgs: ''
        ${dockerBin} run \
          --name ${name}-${unit} \
          --network host \
          --env-file ${environmentFile} \
          --env RAILS_ENV=${railsEnv} \
          --env STASH_STORAGE_SERVICE=disk \
          --env STASH_STORAGE_PATH=${lib.escapeShellArg dataDir} \
          --volume ${lib.escapeShellArg dataDir}:${lib.escapeShellArg dataDir} \
          ${envArgs extraEnv}${extraArgs}--restart no \
          ${lib.escapeShellArg image}'';
    in
    {
      # ── Web (Rails) ─────────────────────────────────────────────────────────
      systemd.services."${name}-web" = lib.recursiveUpdate (common "web") {
        description = "${label} web";
        serviceConfig = {
          ExecStartPre = [
            prepareData
            pull
            "-${dockerBin} stop ${name}-web"
            "-${dockerBin} rm ${name}-web"
          ];
          # Same command as the image's CMD, on the loopback port. The
          # entrypoint matches `./bin/rails server` and migrates first.
          ExecStart = pkgs.writeShellScript "${name}-web-start" ''
            exec ${run "web" ""} \
              ./bin/rails server -b 127.0.0.1 -p ${toString port}
          '';
        };
      };

      # ── Worker (GoodJob) ────────────────────────────────────────────────────
      # Runs the captures. It never migrates, so it waits for the web server,
      # which migrates before it answers /up.
      systemd.services."${name}-worker" = lib.recursiveUpdate (common "worker") {
        description = "${label} worker";
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
                  http://127.0.0.1:${toString port}/up; do
                sleep 5
              done
            '')
          ];
          ExecStart = pkgs.writeShellScript "${name}-worker-start" ''
            exec ${run "worker" "--shm-size 1g --memory ${workerMemory} \\\n  "} \
              bundle exec good_job start
          '';
        };
      };
    };

  instanceOptions = defaults: {
    port = lib.mkOption {
      type = lib.types.port;
      default = defaults.port;
      description = "Loopback port the web server binds to. The host's reverse proxy proxies to it.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/patchworklabsorg/stash:main";
      example = "ghcr.io/patchworklabsorg/stash:0123abc";
      description = ''
        Image ref for web and worker. Pin it to a commit sha for a known build.
        Each start of the web unit pulls it again.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the env file (an agenix secret) with the variables in
        docs/deploy.md of patchworklabsorg/stash: CENTRAL_DATABASE_URL,
        SECRET_KEY_BASE, STASH_HOSTS, WEAVE_ISSUER, WEAVE_CLIENT_ID,
        WEAVE_CLIENT_SECRET, and optionally GITHUB_TOKEN.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = defaults.dataDir;
      description = ''
        Directory on the host that holds the archived files (Active Storage
        disk service). Bind-mounted into both containers at the same path.
        Back it up: it is the archive.
      '';
    };

    workerMemory = lib.mkOption {
      type = lib.types.str;
      default = "3g";
      description = "Docker memory limit of the worker container (Chromium, LibreOffice, yt-dlp).";
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
in
{
  options.patchwork.services.stash = {
    enable = lib.mkEnableOption "Stash, the Patchwork Labs archive";
  }
  // instanceOptions {
    port = 3007;
    dataDir = "/data/stash";
  }
  // {
    staging = {
      enable = lib.mkEnableOption ''
        a Stash staging instance (stash-staging-web and stash-staging-worker,
        RAILS_ENV=staging, own port, image, env file and data dir) alongside
        production
      '';
    }
    // instanceOptions {
      port = 3008;
      dataDir = "/data/stash-staging";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkInstance {
        name = "stash";
        label = "Stash";
        railsEnv = "production";
        inherit (cfg)
          port
          image
          environmentFile
          dataDir
          extraEnv
          workerMemory
          ;
      })

      (lib.mkIf cfg.staging.enable (mkInstance {
        name = "stash-staging";
        label = "Stash staging";
        railsEnv = "staging";
        inherit (cfg.staging)
          port
          image
          environmentFile
          dataDir
          extraEnv
          workerMemory
          ;
      }))
    ]
  );
}
