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
# router names. jaspermayone/infra's modules/traefik does both.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  cfg = config.patchwork.services.quilt;

  # `--env 'KEY=value'` arguments for extraEnv.
  envArgs = lib.concatStrings (
    lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"} \\\n  ") cfg.extraEnv
  );

  # Log in to ghcr.io (when a token is set) and pull the image.
  pull = pkgs.writeShellScript "quilt-pull" ''
    set -e
    ${lib.optionalString (cfg.registryCredentialsFile != null) ''
      ${dockerBin} login ghcr.io \
        --username ${lib.escapeShellArg cfg.registryUsername} \
        --password-stdin < ${cfg.registryCredentialsFile}
    ''}
    ${dockerBin} pull ${lib.escapeShellArg cfg.image}
  '';

  common = name: {
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    # The worker restarts until the schema exists. Never stop retrying.
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "simple";
      # A large new image layer takes longer than systemd's 90-second default.
      TimeoutStartSec = "10min";
      ExecStop = "${dockerBin} stop quilt-${name}";
      Restart = "on-failure";
      RestartSec = "10s";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "quilt-${name}";
    };
  };

  run = name: ''
    ${dockerBin} run \
      --name quilt-${name} \
      --network host \
      --env-file ${cfg.environmentFile} \
      --env RAILS_ENV=production \
      ${envArgs}--restart no \
      ${lib.escapeShellArg cfg.image}'';
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
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # ── Web (Rails) ─────────────────────────────────────────────────────────
        systemd.services.quilt-web = lib.recursiveUpdate (common "web") {
          description = "Quilt web";
          serviceConfig = {
            ExecStartPre = [
              pull
              "-${dockerBin} stop quilt-web"
              "-${dockerBin} rm quilt-web"
            ];
            # Same command as the image's CMD, on the loopback port. The
            # entrypoint matches `./bin/rails server` and migrates first.
            ExecStart = pkgs.writeShellScript "quilt-web-start" ''
              exec ${run "web"} \
                ./bin/rails server -b 127.0.0.1 -p ${toString cfg.port}
            '';
          };
        };

        # ── Worker (GoodJob) ────────────────────────────────────────────────────
        # Runs the jobs and the GoodJob cron (Mercury sync, top-ups). It never
        # migrates, so it waits for the web server, which migrates before it
        # answers /up. One worker only (docs/deploy.md).
        systemd.services.quilt-worker = lib.recursiveUpdate (common "worker") {
          description = "Quilt worker";
          after = [
            "docker.service"
            "quilt-web.service"
          ];
          # `systemctl restart quilt-web` restarts the worker too, after the
          # web server, so both run the same image.
          partOf = [ "quilt-web.service" ];
          serviceConfig = {
            ExecStartPre = [
              pull
              "-${dockerBin} stop quilt-worker"
              "-${dockerBin} rm quilt-worker"
              (pkgs.writeShellScript "quilt-wait-for-web" ''
                echo "Waiting for the web server (migrations)..."
                until ${pkgs.curl}/bin/curl -fsS -o /dev/null \
                    http://127.0.0.1:${toString cfg.port}/up; do
                  sleep 5
                done
              '')
            ];
            ExecStart = pkgs.writeShellScript "quilt-worker-start" ''
              exec ${run "worker"} \
                bundle exec good_job start
            '';
          };
        };
      }

      # ── Traefik ───────────────────────────────────────────────────────────────
      (lib.mkIf cfg.traefik.enable {
        environment.etc."traefik/conf.d/quilt.toml".source = (pkgs.formats.toml { }).generate "quilt.toml" {
          http = {
            routers.quilt = {
              rule = lib.concatMapStringsSep " || " (h: "Host(`${h}`)") cfg.traefik.hosts;
              entryPoints = [ "websecure" ];
              tls.certResolver = cfg.traefik.certResolver;
              inherit (cfg.traefik) middlewares;
              service = "quilt";
            };
            services.quilt.loadBalancer.servers = [
              { url = "http://127.0.0.1:${toString cfg.port}"; }
            ];
          };
        };
      })
    ]
  );
}
