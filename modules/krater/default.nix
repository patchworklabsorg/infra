# modules/krater/default.nix
# Krater — the Project Ganymede portal (proposal review, compute budgets, gallery) — as Docker
# containers on a dedicated network, next to the SkyPilot API server it enforces budgets on. Exported
# by this flake as nixosModules.krater; alastor imports nixosModules.krater-alastor
# (hosts/alastor/krater.nix), which sets the instance options below.
#
# Containers (network `krater`, state under /var/lib/krater):
#   krater-db          Postgres 16
#   krater-storage     SeaweedFS S3 gateway for gallery screenshots (temporary; see Krater's SPEC)
#   krater-web         the portal; runs migrations first        127.0.0.1:<port>
#   krater-worker      procrastinate worker (reconciler, Slack, pricing)
#   krater-auth-proxy  oauth2-proxy: members sign in to SkyPilot with Weave
#   krater-skypilot    SkyPilot API server, Vast only                127.0.0.1:<skypilot.port>
# plus krater-build (builds the image) and krater-backup (nightly pg_dump).
#
# No registry: the image is built on this host from source. krater-build fetches one commit of
# `repo` (a full SHA, read from /var/lib/krater/source-rev, falling back to `rev`), builds it with the
# repo's own Dockerfile and tags it krater:<sha>. It skips the build when that tag already exists.
# A deploy is:
#   echo <sha> > /var/lib/krater/source-rev
#   sudo systemctl start krater-build     # old containers keep serving while this runs
#   sudo systemctl restart krater-web     # migrates, then starts; krater-worker follows (partOf)
# krater-web requires krater-build, so a restart alone also builds, but with the site down meanwhile.
#
# Secrets: one env file (`environmentFile`, an agenix secret), split per container at start into
# /run/krater/*.env so each container gets only its own keys. In particular the SkyPilot server, which
# runs members' work, never sees Krater's session key or database password. The file must contain:
#   POSTGRES_PASSWORD=...                     # URL-safe (token_urlsafe/hex): it goes into a database URL
#   KRATER_SECRET_KEY=...                     # >= 32 chars
#   KRATER_WEAVE_CLIENT_SECRET=...
#   KRATER_SLACK_BOT_TOKEN=...
#   KRATER_SLACK_SIGNING_SECRET=...
#   KRATER_S3_ACCESS_KEY_ID=...
#   KRATER_S3_SECRET_ACCESS_KEY=...
#   KRATER_SKYPILOT_POLICY_TOKEN=...          # >= 32 chars
#   KRATER_SKYPILOT_AUTH_CLIENT_SECRET=...    # the SkyPilot sign-in app's secret in Weave
#   KRATER_SKYPILOT_AUTH_COOKIE_SECRET=...    # 32 random bytes, urlsafe base64
# Two more values only exist after the first start, so they're host state files rather than agenix
# secrets (no infra round trip to set them):
#   /var/lib/krater/secrets/skypilot-basic-auth-password   present only for the one-time bootstrap
#   /var/lib/krater/secrets/skypilot-service-token         Krater's SkyPilot admin token
# The bootstrap is in Krater's docs/dev/production.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork.services.krater;
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";

  stateDir = "/var/lib/krater";
  secretsDir = "${stateDir}/secrets";
  revFile = "${stateDir}/source-rev";
  serviceTokenFile = "${secretsDir}/skypilot-service-token";
  basicAuthFile = "${secretsDir}/skypilot-basic-auth-password";
  envDir = "/run/krater";

  baseUrl = "https://${cfg.domain}";

  # Non-secret settings for the portal, worker and migrations. Krater refuses to start in production
  # with any stub/fake mode, so these are all fixed.
  appEnv = {
    KRATER_ENV = "production";
    KRATER_BASE_URL = baseUrl;
    # The launch gate's base URL. Members' own `sky` CLIs call it, so it's the public one.
    KRATER_PUBLIC_URL = baseUrl;
    # Traefik is the one proxy in front; rate limits key on the client address it forwards.
    KRATER_TRUSTED_PROXY_COUNT = "1";
    KRATER_WEAVE_MODE = "live";
    KRATER_WEAVE_ISSUER = cfg.weave.issuer;
    KRATER_WEAVE_CLIENT_ID = cfg.weave.clientId;
    KRATER_SKYPILOT_MODE = "live";
    KRATER_SKYPILOT_API_URL = "http://krater-skypilot:46580";
    KRATER_SLACK_MODE = "live";
    KRATER_SLACK_FEED_CHANNEL_ID = cfg.slackFeedChannelId;
    KRATER_S3_MODE = "live";
    KRATER_S3_ENDPOINT_URL = "http://krater-storage:8333";
    KRATER_S3_PUBLIC_ENDPOINT_URL = "https://${cfg.storage.domain}";
  }
  // cfg.extraEnv;

  envArgs =
    env:
    lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"}") env);

  # Writes /run/krater/<name>.env with only the listed keys of the env file, renamed `from` -> `to`.
  writeEnvScript =
    name: pairs:
    pkgs.writeShellScript "krater-${name}-env" ''
      set -euo pipefail
      install -d -m 0700 ${envDir}
      umask 077
      sed -n ${
        lib.concatMapStringsSep " " (p: "-e ${lib.escapeShellArg "s/^${p.from}=/${p.to}=/p"}") pairs
      } ${cfg.environmentFile} > ${envDir}/${name}.env
    '';
  same =
    keys:
    map (k: {
      from = k;
      to = k;
    }) keys;

  # The portal and worker get every KRATER_ key except the SkyPilot sign-in proxy's, plus the
  # database URL (built from POSTGRES_PASSWORD so the two can't drift) and the SkyPilot token.
  writeAppEnv = pkgs.writeShellScript "krater-app-env" ''
    set -euo pipefail
    install -d -m 0700 ${envDir}
    umask 077
    password=$(sed -n 's/^POSTGRES_PASSWORD=//p' ${cfg.environmentFile})
    if [ -z "$password" ]; then
      echo "krater: POSTGRES_PASSWORD is missing from ${cfg.environmentFile}" >&2
      exit 1
    fi
    {
      grep -E '^KRATER_' ${cfg.environmentFile} | grep -vE '^KRATER_SKYPILOT_AUTH_(CLIENT_SECRET|COOKIE_SECRET)=' || true
      echo "KRATER_DATABASE_URL=postgresql+psycopg://krater:$password@krater-db:5432/krater"
      if [ -s ${serviceTokenFile} ]; then
        echo "KRATER_SKYPILOT_SERVICE_TOKEN=$(cat ${serviceTokenFile})"
      fi
    } > ${envDir}/app.env
  '';

  # Sets $rev and $image from source-rev (or the `rev` fallback). Only a full SHA is accepted: a
  # branch name would make krater:<tag> stale the moment the branch moved.
  resolveImage = ''
    rev=${lib.escapeShellArg cfg.rev}
    if [ -s ${revFile} ]; then
      rev=$(tr -d '[:space:]' < ${revFile})
    fi
    if ! [[ $rev =~ ^[0-9a-f]{40}$ ]]; then
      echo "krater: '$rev' is not a full 40-character commit SHA (${revFile})" >&2
      exit 1
    fi
    image="krater:$rev"
  '';

  # A `docker run` container as a systemd service, in the style of the Weave module: the unit owns the
  # container's lifecycle (`--restart no`, systemd restarts it).
  mkContainer =
    {
      name,
      description,
      after ? [ ],
      requires ? [ ],
      partOf ? [ ],
      preStart ? [ ],
      start,
      timeoutStart ? null,
    }:
    {
      inherit description partOf;
      after = [
        "docker.service"
        "krater-network.service"
      ]
      ++ after;
      requires = [
        "docker.service"
        "krater-network.service"
      ]
      ++ requires;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          "-${dockerBin} stop krater-${name}"
          "-${dockerBin} rm krater-${name}"
        ]
        ++ preStart;
        ExecStart = pkgs.writeShellScript "krater-${name}-start" start;
        ExecStop = "${dockerBin} stop krater-${name}";
        Restart = "on-failure";
        RestartSec = "10s";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "krater-${name}";
      }
      // lib.optionalAttrs (timeoutStart != null) { TimeoutStartSec = timeoutStart; };
    };

  pull = image: "${dockerBin} pull ${image}";
in
{
  options.patchwork.services.krater = {
    enable = lib.mkEnableOption "Krater, the Project Ganymede portal";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/patchworklabsorg/krater.git";
      description = "Git repository krater-build fetches the source from. Must be readable without credentials.";
    };

    rev = lib.mkOption {
      type = lib.types.strMatching "[0-9a-f]{40}";
      description = ''
        Fallback commit (full SHA) to build when /var/lib/krater/source-rev is empty. Deploys write
        source-rev instead of changing this. Must be pushed to `repo`.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = "Env file (an agenix secret) with the keys listed at the top of this module.";
    };

    vastKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File holding the Vast.ai API key SkyPilot launches with (an agenix secret).";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "krater.patchworklabs.org";
      description = "Public hostname of the portal. Slack and members' `sky` CLIs call it too.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3010;
      description = "Loopback host port for the portal container (Traefik proxies to it).";
    };

    slackFeedChannelId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Slack channel id for the public project feed. Empty turns the feed off.";
    };

    weave = {
      issuer = lib.mkOption {
        type = lib.types.str;
        example = "https://idp.patchworklabs.org";
        description = "Weave's OIDC issuer URL, exactly as its discovery document states it.";
      };
      clientId = lib.mkOption {
        type = lib.types.str;
        description = "Client id of Krater's Weave app (redirect URI https://<domain>/auth/callback).";
      };
      skypilotClientId = lib.mkOption {
        type = lib.types.str;
        description = "Client id of the separate Weave app for the SkyPilot sign-in proxy.";
      };
    };

    storage = {
      domain = lib.mkOption {
        type = lib.types.str;
        example = "storage.krater.patchworklabs.org";
        description = "Public hostname of the screenshot bucket. Browsers upload to it directly.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3011;
        description = "Loopback host port for the S3 gateway.";
      };
      image = lib.mkOption {
        type = lib.types.str;
        default = "chrislusf/seaweedfs:latest";
        description = "SeaweedFS image. Pin a version once staging has run against one.";
      };
    };

    skypilot = {
      domain = lib.mkOption {
        type = lib.types.str;
        example = "sky.krater.patchworklabs.org";
        description = "Public hostname of the SkyPilot API server (`sky api login -e https://<this>`).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3012;
        description = "Loopback host port for the SkyPilot API server (also used for the bootstrap).";
      };
      image = lib.mkOption {
        type = lib.types.str;
        # Krater pins SkyPilot in scripts/dev/skypilot-requirements.txt; keep this tag the same.
        default = "berkeleyskypilot/skypilot:0.13.0";
        description = "SkyPilot API server image.";
      };
      authProxyImage = lib.mkOption {
        type = lib.types.str;
        default = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0";
        description = "oauth2-proxy image for the SkyPilot sign-in proxy.";
      };
    };

    postgresImage = lib.mkOption {
      type = lib.types.str;
      default = "postgres:16";
      description = "Postgres image. A major version change needs a dump and restore.";
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        KRATER_SKYPILOT_BUDGET_WARN_PERCENT = "80";
      };
      description = "Extra non-secret settings for the portal, worker and migrations.";
    };

    backup = {
      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 03:30:00";
        description = "When krater-backup dumps the database (systemd OnCalendar).";
      };
      keepDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 14;
        description = "Dumps in /var/lib/krater/backups older than this are deleted.";
      };
    };

    deployAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys for the krater-deploy CI user. That user may write
        /var/lib/krater/source-rev and run only:
          sudo systemctl start krater-build
          sudo systemctl restart krater-web
      '';
    };

    traefik = {
      enable = lib.mkEnableOption ''
        a Traefik file-provider fragment (/etc/traefik/conf.d/krater.toml) routing the portal,
        screenshot and SkyPilot hostnames
      '';
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
        assertions =
          map
            (name: {
              assertion = cfg.weave.${name} != "";
              message = "patchwork.services.krater.weave.${name} must be set";
            })
            [
              "issuer"
              "clientId"
              "skypilotClientId"
            ];

        # ── State ───────────────────────────────────────────────────────────────
        systemd.tmpfiles.rules = [
          "d ${secretsDir} 0700 root root -"
        ]
        ++ lib.optionals (cfg.deployAuthorizedKeys != [ ]) [
          "f ${revFile} 0644 krater-deploy users -"
          "z ${revFile} 0644 krater-deploy users -"
        ];

        # ── Docker network ──────────────────────────────────────────────────────
        systemd.services.krater-network = {
          description = "Create krater Docker network";
          after = [ "docker.service" ];
          requires = [ "docker.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "krater krater/db krater/storage krater/skypilot krater/backups";
            StateDirectoryMode = "0750";
            ExecStart = pkgs.writeShellScript "krater-network-create" ''
              ${dockerBin} network inspect krater >/dev/null 2>&1 || \
                ${dockerBin} network create krater
            '';
          };
        };

        # ── Image build ─────────────────────────────────────────────────────────
        # A oneshot of its own, not part of krater-web's start: the first build of the Python
        # dependencies takes minutes, far past a service's start timeout, and a deploy can run it
        # while the old containers keep serving.
        systemd.services.krater-build = {
          description = "Build the Krater image from source";
          after = [
            "docker.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          requires = [ "docker.service" ];
          path = [
            pkgs.git
            config.virtualisation.docker.package
          ];
          # The Dockerfile uses BuildKit cache mounts.
          environment.DOCKER_BUILDKIT = "1";
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "45min";
            StandardOutput = "journal";
            StandardError = "journal";
            SyslogIdentifier = "krater-build";
          };
          script = ''
            set -euo pipefail
            ${resolveImage}
            if docker image inspect "$image" >/dev/null 2>&1; then
              echo "krater: $image is already built"
            else
              # Fetched here rather than handed to `docker build` as a git URL, which would need
              # git inside the Docker daemon's own PATH.
              src=$(mktemp -d)
              trap 'rm -rf "$src"' EXIT
              git -C "$src" init -q
              git -C "$src" fetch -q --depth 1 ${lib.escapeShellArg cfg.repo} "$rev"
              git -C "$src" checkout -q FETCH_HEAD
              docker build --label "org.patchworklabs.krater.rev=$rev" --tag "$image" "$src"
            fi
            # Drop older builds so the disk doesn't fill. An image a container still runs can't be
            # removed, so the running version survives until after the restart.
            docker image ls krater --format '{{.Tag}}' | { grep -vx "$rev" || true; } | while read -r tag; do
              docker rmi "krater:$tag" >/dev/null 2>&1 || true
            done
          '';
        };

        # ── Postgres ────────────────────────────────────────────────────────────
        systemd.services.krater-db = mkContainer {
          name = "db";
          description = "Krater PostgreSQL";
          preStart = [
            (pull cfg.postgresImage)
            (writeEnvScript "db" (same [ "POSTGRES_PASSWORD" ]))
          ];
          start = ''
            exec ${dockerBin} run \
              --name krater-db \
              --network krater \
              --env-file ${envDir}/db.env \
              --env POSTGRES_USER=krater \
              --env POSTGRES_DB=krater \
              --volume ${stateDir}/db:/var/lib/postgresql/data \
              --restart no \
              ${cfg.postgresImage}
          '';
        };

        # ── Screenshot storage (SeaweedFS) ──────────────────────────────────────
        systemd.services.krater-storage = mkContainer {
          name = "storage";
          description = "Krater screenshot storage (SeaweedFS)";
          preStart = [
            (pull cfg.storage.image)
            (writeEnvScript "storage" [
              {
                from = "KRATER_S3_ACCESS_KEY_ID";
                to = "S3_ACCESS_KEY";
              }
              {
                from = "KRATER_S3_SECRET_ACCESS_KEY";
                to = "S3_SECRET_KEY";
              }
            ])
          ];
          start = ''
            exec ${dockerBin} run \
              --name krater-storage \
              --network krater \
              --publish 127.0.0.1:${toString cfg.storage.port}:8333 \
              --env-file ${envDir}/storage.env \
              --volume ${stateDir}/storage:/data \
              --volume ${./storage-start.sh}:/krater/storage-start.sh:ro \
              --entrypoint /bin/sh \
              --restart no \
              ${cfg.storage.image} /krater/storage-start.sh
          '';
        };

        # ── Portal ──────────────────────────────────────────────────────────────
        systemd.services.krater-web = mkContainer {
          name = "web";
          description = "Krater web";
          after = [
            "krater-build.service"
            "krater-db.service"
            "krater-storage.service"
          ];
          requires = [
            "krater-build.service"
            "krater-db.service"
            "krater-storage.service"
          ];
          # Waiting for Postgres and running migrations can outlast the default 90s.
          timeoutStart = "10min";
          preStart = [
            (pkgs.writeShellScript "krater-web-prepare" ''
              set -euo pipefail
              ${resolveImage}
              if ! ${dockerBin} image inspect "$image" >/dev/null 2>&1; then
                echo "krater: $image isn't built; run: systemctl start krater-build" >&2
                exit 1
              fi
              ${writeAppEnv}
              echo "$image" > ${envDir}/image

              echo "Waiting for postgres..."
              until ${dockerBin} exec krater-db pg_isready -U krater -q; do
                sleep 2
              done
              # Migrations, then the screenshot bucket and its CORS rule. Both are idempotent.
              ${dockerBin} run --rm \
                --network krater \
                --env-file ${envDir}/app.env \
                ${envArgs appEnv} \
                "$image" \
                sh -c 'alembic upgrade head && python -m krater.storage.ensure_bucket'
            '')
          ];
          start = ''
            exec ${dockerBin} run \
              --name krater-web \
              --network krater \
              --publish 127.0.0.1:${toString cfg.port}:8000 \
              --env-file ${envDir}/app.env \
              ${envArgs appEnv} \
              --restart no \
              "$(cat ${envDir}/image)"
          '';
        };

        # ── Worker ──────────────────────────────────────────────────────────────
        systemd.services.krater-worker = mkContainer {
          name = "worker";
          description = "Krater worker (procrastinate)";
          # Runs the image and env krater-web just prepared, after its migrations. partOf carries a
          # deploy's `restart krater-web` over to the worker, as in the Weave module.
          after = [ "krater-web.service" ];
          requires = [ "krater-web.service" ];
          partOf = [ "krater-web.service" ];
          start = ''
            exec ${dockerBin} run \
              --name krater-worker \
              --network krater \
              --env-file ${envDir}/app.env \
              ${envArgs appEnv} \
              --restart no \
              "$(cat ${envDir}/image)" \
              procrastinate --app=krater.worker.app.app worker
          '';
        };

        # ── SkyPilot sign-in proxy ──────────────────────────────────────────────
        # Any Weave user can sign in here; private per-project workspaces and Krater's launch gate do
        # the limiting (Krater's docs/skypilot-integration.md section 0).
        systemd.services.krater-auth-proxy = mkContainer {
          name = "auth-proxy";
          description = "Krater SkyPilot sign-in proxy (oauth2-proxy)";
          preStart = [
            (pull cfg.skypilot.authProxyImage)
            (writeEnvScript "auth-proxy" [
              {
                from = "KRATER_SKYPILOT_AUTH_CLIENT_SECRET";
                to = "OAUTH2_PROXY_CLIENT_SECRET";
              }
              {
                from = "KRATER_SKYPILOT_AUTH_COOKIE_SECRET";
                to = "OAUTH2_PROXY_COOKIE_SECRET";
              }
            ])
          ];
          start = ''
            exec ${dockerBin} run \
              --name krater-auth-proxy \
              --network krater \
              --env-file ${envDir}/auth-proxy.env \
              ${
                envArgs {
                  OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:4180";
                  OAUTH2_PROXY_UPSTREAMS = "http://krater-skypilot:46580";
                  OAUTH2_PROXY_PROVIDER = "oidc";
                  OAUTH2_PROXY_OIDC_ISSUER_URL = cfg.weave.issuer;
                  OAUTH2_PROXY_CLIENT_ID = cfg.weave.skypilotClientId;
                  OAUTH2_PROXY_REDIRECT_URL = "https://${cfg.skypilot.domain}/oauth2/callback";
                  OAUTH2_PROXY_SCOPE = "openid email profile";
                  OAUTH2_PROXY_EMAIL_DOMAINS = "*";
                  OAUTH2_PROXY_CODE_CHALLENGE_METHOD = "S256";
                  OAUTH2_PROXY_COOKIE_EXPIRE = "8h";
                  OAUTH2_PROXY_COOKIE_SECURE = "true";
                }
              } \
              --restart no \
              ${cfg.skypilot.authProxyImage}
          '';
        };

        # ── SkyPilot API server ─────────────────────────────────────────────────
        systemd.services.krater-skypilot = mkContainer {
          name = "skypilot";
          description = "Krater SkyPilot API server";
          after = [ "krater-auth-proxy.service" ];
          requires = [ "krater-auth-proxy.service" ];
          timeoutStart = "5min";
          preStart = [
            (pull cfg.skypilot.image)
            # Only the policy token from the env file. Basic auth is on only while its password
            # file exists: SkyPilot checks basic auth before asking auth-proxy, so leaving it on
            # blocks every member's sign-in.
            (pkgs.writeShellScript "krater-skypilot-env" ''
              set -euo pipefail
              install -d -m 0700 ${envDir}
              umask 077
              {
                grep -E '^KRATER_SKYPILOT_POLICY_TOKEN=' ${cfg.environmentFile} || true
                if [ -s ${basicAuthFile} ]; then
                  echo "ENABLE_BASIC_AUTH=true"
                  echo "SKYPILOT_BASIC_AUTH_PASSWORD=$(cat ${basicAuthFile})"
                else
                  echo "ENABLE_BASIC_AUTH=false"
                fi
              } > ${envDir}/skypilot.env
            '')
          ];
          start = ''
            exec ${dockerBin} run \
              --name krater-skypilot \
              --network krater \
              --publish 127.0.0.1:${toString cfg.skypilot.port}:46580 \
              --env-file ${envDir}/skypilot.env \
              ${
                envArgs {
                  KRATER_PUBLIC_URL = baseUrl;
                  ENABLE_SERVICE_ACCOUNTS = "true";
                  SKYPILOT_AUTH_OAUTH2_PROXY_ENABLED = "true";
                  SKYPILOT_AUTH_OAUTH2_PROXY_BASE_URL = "http://krater-auth-proxy:4180";
                  SKYPILOT_BASIC_AUTH_USER = "admin";
                }
              } \
              --volume ${stateDir}/skypilot:/root/.sky \
              --volume ${./skypilot-start.sh}:/krater/skypilot-start.sh:ro \
              ${
                lib.optionalString (
                  cfg.vastKeyFile != null
                ) "--volume ${cfg.vastKeyFile}:/root/.config/vastai/vast_api_key:ro"
              } \
              --entrypoint /bin/sh \
              --restart no \
              ${cfg.skypilot.image} /krater/skypilot-start.sh
          '';
        };

        # ── Backups ─────────────────────────────────────────────────────────────
        # The budget ledger and audit log live only in this database. Copy /var/lib/krater/backups
        # off the host; screenshots (/var/lib/krater/storage) aren't in these dumps.
        systemd.services.krater-backup = {
          description = "Dump the Krater database";
          after = [ "krater-db.service" ];
          requires = [ "krater-db.service" ];
          serviceConfig = {
            Type = "oneshot";
            SyslogIdentifier = "krater-backup";
          };
          script = ''
            set -euo pipefail
            dir=${stateDir}/backups
            name="krater-$(date -u +%Y%m%dT%H%M%SZ).dump"
            trap 'rm -f "$dir/$name.partial"' EXIT
            ${dockerBin} exec krater-db pg_dump --format=custom -U krater krater > "$dir/$name.partial"
            mv "$dir/$name.partial" "$dir/$name"
            echo "backup written: $name"
            find "$dir" -name 'krater-*.dump' -mtime +${toString cfg.backup.keepDays} -delete
          '';
        };
        systemd.timers.krater-backup = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.backup.onCalendar;
            Persistent = true;
          };
        };
      }

      # ── CI deploy user ──────────────────────────────────────────────────────────
      (lib.mkIf (cfg.deployAuthorizedKeys != [ ]) {
        users.users.krater-deploy = {
          isNormalUser = true;
          group = "users";
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = cfg.deployAuthorizedKeys;
        };
        security.sudo.extraRules = [
          {
            users = [ "krater-deploy" ];
            commands = [
              {
                command = "/run/current-system/sw/bin/systemctl start krater-build";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl restart krater-web";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];
      })

      # ── Traefik ───────────────────────────────────────────────────────────────
      # The launch gate (/internal/skypilot/policy) must stay reachable through the portal router:
      # members' own `sky` CLIs call it before every launch.
      (lib.mkIf cfg.traefik.enable {
        environment.etc."traefik/conf.d/krater.toml".source =
          let
            router = host: service: {
              rule = "Host(`${host}`)";
              entryPoints = [ "websecure" ];
              tls.certResolver = cfg.traefik.certResolver;
              inherit (cfg.traefik) middlewares;
              inherit service;
            };
            backend = port: {
              loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
            };
          in
          (pkgs.formats.toml { }).generate "krater.toml" {
            http = {
              routers = {
                krater = router cfg.domain "krater";
                krater-storage = router cfg.storage.domain "krater-storage";
                krater-skypilot = router cfg.skypilot.domain "krater-skypilot";
              };
              services = {
                krater = backend cfg.port;
                krater-storage = backend cfg.storage.port;
                krater-skypilot = backend cfg.skypilot.port;
              };
            };
          };
      })
    ]
  );
}
