# modules/quilt/default.nix
# Quilt: Patchwork Labs funding and records (Rails). Two Docker containers from
# one image: web and worker. Exported by this flake as nixosModules.quilt; the
# host that runs it imports nixosModules.quilt-alastor
# (hosts/alastor/quilt.nix), which sets the instance options below.
#
# The contract with the app is docs/deploy.md in patchworklabsorg/quilt.
#
# Database: Quilt has no database of its own. It connects only to
# patchwork_central_restricted (seam, prod) as the role `quilt`, which owns the
# schema `quilt` (hosts/central-db-schema.nix). The env file holds the full
# RESTRICTED_DATABASE_URL, password included:
#   postgres://quilt:<password>@seam.wildebeest-stargazer.ts.net:5432/patchwork_central_restricted?sslmode=disable
# The password must be the one in secrets/restricted-prod-quilt.age, which seam
# sets on the role. seam has no server TLS yet (modules/central-db); Tailscale
# encrypts the path, hence sslmode=disable.
#
# Network: both containers use the host network (`--network host`). seam is
# reachable only over the tailnet, and the host resolves its MagicDNS name and
# routes 100.64.0.0/10. A Docker bridge does not reliably resolve *.ts.net
# names. So the web server binds 127.0.0.1:<port> itself, and Traefik proxies
# to that address.
#
# Units:
#   quilt-web     pulls the image, runs `./bin/rails server`. The image's
#                 entrypoint runs `db:migrate` before the server starts.
#   quilt-worker  `bundle exec good_job start`. Waits for GET /up on the web
#                 server (so the migrations ran), and restarts on failure
#                 until the schema is there. partOf quilt-web, so
#                 `systemctl restart quilt-web` moves both to a new image.
#
# Image: `image` is a full ref. The default tag `main` follows the newest push
# to main. Pin it to `ghcr.io/patchworklabsorg/quilt:<sha>` for a known build.
# Each start pulls the ref again, so `systemctl restart quilt-web` deploys the
# newest `main`.
#
# Traefik routing (`traefik.*` options) is a fragment in
# /etc/traefik/conf.d/quilt.toml. The host's Traefik must use the file
# provider on that directory and define the cert resolver and middlewares the
# routers name. jaspermayone/infra's modules/traefik does both.
#
# Staging (optional, `staging.enable`) is a second, separate instance from the
# same `mkInstance` function below: units and containers quilt-staging-web and
# quilt-staging-worker, its own port, image, env file and extraEnv, router
# `quilt-staging` in the same Traefik fragment. It runs with
# RAILS_ENV=staging. In that environment Quilt requires the Mercury sandbox
# URL and refuses the live one, so staging cannot move real money. Its
# database is patchwork_central_restricted on hem:5433 (the restricted staging
# cluster), not seam. The registry login is shared with production.
#
# The production units must stay byte-identical when staging is added or
# changed. Keep every production name and script name in `mkInstance` derived
# from name = "quilt", and keep an empty `extraEnv` free of characters.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  cfg = config.patchwork.services.quilt;

  # `--env 'KEY=value'` arguments for an instance's extraEnv. Each line ends
  # with the two-space indent the next docker argument expects. An empty
  # attrset renders "", which keeps the production units identical.
  envArgs =
    env:
    lib.concatStrings (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"} \\\n  ") env);

  # Every unit, container and script name of one Quilt instance comes from
  # `name`. Production is name = "quilt".
  #   name             unit, container and script prefix
  #   label            human prefix for unit descriptions ("Quilt")
  #   railsEnv         RAILS_ENV for both containers
  #   port             loopback port of the web server
  #   image            image ref, pulled on each start
  #   environmentFile  agenix env file (docs/deploy.md of patchworklabsorg/quilt)
  #   extraEnv         extra container env; it overrides the env file
  mkInstance =
    {
      name,
      label,
      railsEnv,
      port,
      image,
      environmentFile,
      extraEnv,
    }:
    let
      # Log in to ghcr.io (when a token is set) and pull the image.
      pull = pkgs.writeShellScript "${name}-pull" ''
        set -e
        ${lib.optionalString (cfg.registryCredentialsFile != null) ''
          ${dockerBin} login ghcr.io \
            --username ${lib.escapeShellArg cfg.registryUsername} \
            --password-stdin < ${cfg.registryCredentialsFile}
        ''}
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
          # A large new image layer takes longer than systemd's 90-second default.
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
          --env-file ${environmentFile} \
          --env RAILS_ENV=${railsEnv} \
          ${envArgs extraEnv}--restart no \
          ${lib.escapeShellArg image}'';
    in
    {
      # ── Web (Rails) ─────────────────────────────────────────────────────────
      systemd.services."${name}-web" = lib.recursiveUpdate (common "web") {
        description = "${label} web";
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
              ./bin/rails server -b 127.0.0.1 -p ${toString port}
          '';
        };
      };

      # ── Worker (GoodJob) ────────────────────────────────────────────────────
      # Runs the jobs and the GoodJob cron (Mercury sync, top-ups). It never
      # migrates, so it waits for the web server, which migrates before it
      # answers /up. One worker only (docs/deploy.md).
      systemd.services."${name}-worker" = lib.recursiveUpdate (common "worker") {
        description = "${label} worker";
        after = [
          "docker.service"
          "${name}-web.service"
        ];
        # `systemctl restart <name>-web` restarts the worker too, after the
        # web server, so both run the same image.
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
            exec ${run "worker"} \
              bundle exec good_job start
          '';
        };
      };
    };
in
{
  options.patchwork.services.quilt = {
    enable = lib.mkEnableOption "Quilt, Patchwork Labs funding and records";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3005;
      description = "Loopback port the web server binds to. Traefik proxies to it.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/patchworklabsorg/quilt:main";
      example = "ghcr.io/patchworklabsorg/quilt:0123abc";
      description = ''
        Image ref for web and worker. Pin it to a commit sha for a known build.
        Each start of quilt-web pulls it again.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the env file (an agenix secret) with the variables in
        docs/deploy.md of patchworklabsorg/quilt: RESTRICTED_DATABASE_URL,
        SECRET_KEY_BASE, WEAVE_ISSUER, WEAVE_CLIENT_ID, WEAVE_CLIENT_SECRET,
        MERCURY_API_TOKEN, MERCURY_API_BASE, MERCURY_WRITE_TOKEN,
        QUILT_TOPUPS.
      '';
    };

    registryCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file with a GitHub token (classic PAT, read:packages) that
        can read the private ghcr.io/patchworklabsorg/quilt package. null:
        pull without a login.
      '';
    };

    registryUsername = lib.mkOption {
      type = lib.types.str;
      default = "patchworklabsorg";
      description = "Username for the ghcr.io login. Use the GitHub login that owns the token.";
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

    traefik = {
      enable = lib.mkEnableOption ''
        a Traefik file-provider fragment (/etc/traefik/conf.d/quilt.toml) that
        routes `hosts` to the web server
      '';

      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "quilt.patchworklabs.org" ];
        description = "Hostnames routed to the web server (router `quilt`).";
      };

      certResolver = lib.mkOption {
        type = lib.types.str;
        default = "cloudflare";
        description = "Name of a cert resolver defined in the host's Traefik static config.";
      };

      middlewares = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "hsts" ];
        description = "Middlewares, by name, defined elsewhere in the same file provider.";
      };
    };

    staging = {
      enable = lib.mkEnableOption ''
        a Quilt staging instance (quilt-staging-web and quilt-staging-worker,
        RAILS_ENV=staging, own port, image and env file) alongside production
      '';

      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "quilt-staging.patchworklabs.org" ];
        description = ''
          Hostnames routed to the staging web server (router
          `quilt-staging`). Used only when `traefik.enable` is set.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3006;
        description = "Loopback port the staging web server binds to.";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/patchworklabsorg/quilt:main";
        example = "ghcr.io/patchworklabsorg/quilt:0123abc";
        description = ''
          Image ref for the staging web and worker. Each start of
          quilt-staging-web pulls it again. The image must have the `staging`
          Rails environment (config/environments/staging.rb).
        '';
      };

      environmentFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to the staging env file (an agenix secret). Same variables as
          `environmentFile`, but RESTRICTED_DATABASE_URL points at the
          restricted staging cluster (hem:5433), the Weave client is a Weave
          staging app, and the Mercury tokens are sandbox tokens.
        '';
      };

      extraEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          MERCURY_API_BASE = "https://api-sandbox.mercury.com/api/v1/";
          WEAVE_ISSUER = "https://weave-staging.patchworklabs.org";
        };
        description = ''
          Extra container env for the staging web and worker. It overrides the
          staging env file. RAILS_ENV=staging is always set.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ── Production ────────────────────────────────────────────────────────────
      (mkInstance {
        name = "quilt";
        label = "Quilt";
        railsEnv = "production";
        inherit (cfg)
          port
          image
          environmentFile
          extraEnv
          ;
      })

      # ── Staging ───────────────────────────────────────────────────────────────
      (lib.mkIf cfg.staging.enable (mkInstance {
        name = "quilt-staging";
        label = "Quilt staging";
        railsEnv = "staging";
        inherit (cfg.staging)
          port
          image
          environmentFile
          extraEnv
          ;
      }))

      # ── Traefik ───────────────────────────────────────────────────────────────
      # Router and service `quilt` for production, `quilt-staging` for staging.
      (lib.mkIf cfg.traefik.enable {
        environment.etc."traefik/conf.d/quilt.toml".source =
          let
            router = hosts: service: {
              rule = lib.concatMapStringsSep " || " (h: "Host(`${h}`)") hosts;
              entryPoints = [ "websecure" ];
              tls.certResolver = cfg.traefik.certResolver;
              inherit (cfg.traefik) middlewares;
              inherit service;
            };
            backend = port: {
              loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
            };
            withStaging = cfg.staging.enable && cfg.staging.hosts != [ ];
          in
          (pkgs.formats.toml { }).generate "quilt.toml" {
            http = {
              routers = {
                quilt = router cfg.traefik.hosts "quilt";
              }
              // lib.optionalAttrs withStaging {
                quilt-staging = router cfg.staging.hosts "quilt-staging";
              };
              services = {
                quilt = backend cfg.port;
              }
              // lib.optionalAttrs withStaging {
                quilt-staging = backend cfg.staging.port;
              };
            };
          };
      })
    ]
  );
}
