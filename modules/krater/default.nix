# modules/krater/default.nix
# Krater — the Project Ganymede portal (proposal review, compute budgets, gallery, and Krater Compute,
# which rents Vast.ai machines for members) — as Docker containers on a dedicated network. Exported by this
# flake as nixosModules.krater; alastor imports nixosModules.krater-alastor (hosts/alastor/krater.nix), which
# sets the instance options below.
#
# Containers (network `krater`, state under /var/lib/krater):
#   krater-db          Postgres 16
#   krater-storage     SeaweedFS S3 gateway: gallery screenshots, and machines' checkpoints and outputs
#   krater-web         the portal, the runner API rented machines call; runs migrations first   127.0.0.1:<port>
#   krater-worker      procrastinate worker (the compute scheduler, Slack, pricing)
# plus krater-build (builds the image) and krater-backup (nightly pg_dump).
#
# Krater Compute is off by default (`compute.enable = false`, KRATER_COMPUTE_MODE=off): Krater launches
# nothing and needs no Vast key. On, the worker rents with the Vast key (`compute.vastKeyFile`), which only the
# worker ever sees; rented machines reach the portal at `compute.runnerUrl` (the public portal hostname) and
# the storage hostname. See Krater's docs/compute/.
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
# /run/krater/*.env so each container gets only its own keys. The file must contain:
#   POSTGRES_PASSWORD=...                     # URL-safe (token_urlsafe/hex): it goes into a database URL
#   KRATER_SECRET_KEY=...                     # >= 32 chars
#   KRATER_WEAVE_CLIENT_SECRET=...
#   KRATER_SLACK_BOT_TOKEN=...
#   KRATER_SLACK_SIGNING_SECRET=...
#   KRATER_S3_ACCESS_KEY_ID=...
#   KRATER_S3_SECRET_ACCESS_KEY=...
# Two more secrets are files of their own (agenix), each read into one container's env only:
#   compute.vastKeyFile      the Vast.ai API key, worker only (KRATER_VAST_API_KEY)
#   projectSecretsKeyFile    Fernet keys for project secrets, one per line, newest first; portal only
#                            (KRATER_PROJECT_SECRETS_KEY). Losing it loses every stored project secret.
# The image runs as a non-root user, so a root-only agenix file can't be mounted in; the env files are root-only
# (0600 in /run/krater, 0700), like the rest.
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
  envDir = "/run/krater";

  baseUrl = "https://${cfg.domain}";

  # Non-secret settings for the portal, worker and migrations. Krater refuses to start in production
  # with any stub/fake mode, so these are all fixed.
  appEnv = {
    KRATER_ENV = "production";
    KRATER_BASE_URL = baseUrl;
    # Proxies that append to X-Forwarded-For: Traefik. Raise it through extraEnv when another proxy
    # (Cloudflare) is in front too; rate limits key on the client address this picks out.
    KRATER_TRUSTED_PROXY_COUNT = "1";
    KRATER_WEAVE_MODE = "live";
    KRATER_WEAVE_ISSUER = cfg.weave.issuer;
    KRATER_WEAVE_CLIENT_ID = cfg.weave.clientId;
    KRATER_COMPUTE_MODE = if cfg.compute.enable then "vast" else "off";
    # Live even with compute off: the budget estimator's GPU prices come from a public catalog on GitHub.
    KRATER_PRICING_MODE = "live";
    KRATER_SLACK_MODE = "live";
    KRATER_SLACK_FEED_CHANNEL_ID = cfg.slackFeedChannelId;
    KRATER_S3_MODE = "live";
    KRATER_S3_ENDPOINT_URL = "http://krater-storage:8333";
    KRATER_S3_PUBLIC_ENDPOINT_URL = "https://${cfg.storage.domain}";
  }
  // lib.optionalAttrs cfg.compute.enable {
    KRATER_VAST_MODE = "live";
    # The scheduler destroys unknown instances with this prefix: unique per deployment on one Vast account.
    KRATER_COMPUTE_LABEL_PREFIX = cfg.compute.labelPrefix;
    KRATER_COMPUTE_RUNNER_URL = cfg.compute.runnerUrl;
  }
  // lib.optionalAttrs (cfg.weave.cliClientId != "") {
    KRATER_WEAVE_CLI_CLIENT_ID = cfg.weave.cliClientId;
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

  # The portal and worker get every KRATER_ key of the env file, plus the database URL (built from
  # POSTGRES_PASSWORD so the two can't drift).
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
      grep -E '^KRATER_' ${cfg.environmentFile} || true
      echo "KRATER_DATABASE_URL=postgresql+psycopg://krater:$password@krater-db:5432/krater"
    } > ${envDir}/app.env
  '';

  # The portal's env: app.env plus the project-secrets keys (comma-separated, newest first).
  writeWebEnv = pkgs.writeShellScript "krater-web-env" ''
    set -euo pipefail
    umask 077
    {
      cat ${envDir}/app.env
      ${lib.optionalString (cfg.projectSecretsKeyFile != null) ''
        keys=$(grep -vE '^[[:space:]]*(#|$)' ${cfg.projectSecretsKeyFile} | tr -d '[:blank:]' | paste -sd, -)
        echo "KRATER_PROJECT_SECRETS_KEY=$keys"
      ''}
    } > ${envDir}/web.env
  '';

  # The worker's env: app.env plus the Vast key. Nothing else ever gets the key.
  writeWorkerEnv = pkgs.writeShellScript "krater-worker-env" ''
    set -euo pipefail
    umask 077
    {
      cat ${envDir}/app.env
      ${lib.optionalString cfg.compute.enable ''
        echo "KRATER_VAST_API_KEY=$(tr -d '[:space:]' < ${cfg.compute.vastKeyFile})"
      ''}
    } > ${envDir}/worker.env
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

    projectSecretsKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Fernet keys for project secrets (an agenix secret): one per line, newest first, so a key can be
        rotated by adding a new first line. Read into the portal's env only. Null turns project secrets off.
        Losing it loses every stored project secret.
      '';
    };

    domain = lib.mkOption {
      type = lib.types.str;
      example = "krater.patchworklabs.org";
      description = "Public hostname of the portal. Slack, the `krater` CLI and rented machines' runners call it too.";
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
        example = "https://weave.patchworklabs.org";
        description = "Weave's OIDC issuer URL, exactly as its discovery document states it.";
      };
      clientId = lib.mkOption {
        type = lib.types.str;
        description = "Client id of Krater's Weave app (redirect URI https://<domain>/auth/callback).";
      };
      cliClientId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Client id of the `krater` CLI's public Weave app (redirect URI urn:ietf:wg:oauth:2.0:oob; Krater's
          docs/compute/cli.md). Empty turns the CLI's API off.
        '';
      };
    };

    storage = {
      domain = lib.mkOption {
        type = lib.types.str;
        example = "krater-storage.patchworklabs.org";
        description = "Public hostname of the bucket. Browsers upload screenshots to it, and rented machines their checkpoints.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3011;
        description = "Loopback host port for the S3 gateway.";
      };
      image = lib.mkOption {
        type = lib.types.str;
        default = "chrislusf/seaweedfs:4.47";
        description = "SeaweedFS image. 4.47 is the version Krater's staging ran; bump it only after a staging run.";
      };
    };

    compute = {
      enable = lib.mkEnableOption ''
        Krater Compute: the worker rents Vast.ai machines for members' jobs and boxes
        (KRATER_COMPUTE_MODE=vast). Turn it on only after Krater's paid checks in docs/compute/README.md
      '';
      vastKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File holding the Vast.ai API key (an agenix secret, the bare key). Read into the worker's env only.";
      };
      labelPrefix = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]+-";
        default = "krater-prod-";
        description = ''
          Label prefix of the instances this deployment rents. The scheduler destroys instances with this
          prefix that it doesn't know, so no other deployment or script on the same Vast account may use it.
        '';
      };
      runnerUrl = lib.mkOption {
        type = lib.types.str;
        default = baseUrl;
        defaultText = lib.literalExpression ''"https://''${domain}"'';
        description = "Where rented machines reach Krater (the runner downloads itself from here and reports to it).";
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
        KRATER_BUDGET_WARN_PERCENT = "80";
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
        a Traefik file-provider fragment (/etc/traefik/conf.d/krater.toml) routing the portal and
        storage hostnames
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
            ]
          ++ [
            {
              assertion = cfg.compute.enable -> cfg.compute.vastKeyFile != null;
              message = "patchwork.services.krater.compute.vastKeyFile must be set when compute.enable is true";
            }
          ];

        # ── State ───────────────────────────────────────────────────────────────
        # /var/lib/krater itself stays 0755 (as in the Weave module) so krater-deploy can reach
        # source-rev. Backups hold the whole database and secrets hold tokens: root only.
        systemd.tmpfiles.rules = [
          "d ${secretsDir} 0700 root root -"
          "d ${stateDir}/backups 0700 root root -"
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
            # Not backups/ or secrets/: StateDirectoryMode is reapplied on every start, and those
            # two stay 0700 (tmpfiles rules above).
            StateDirectory = "krater krater/db krater/storage";
            StateDirectoryMode = "0755";
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
              ${writeWebEnv}
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
              --env-file ${envDir}/web.env \
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
          preStart = [ writeWorkerEnv ];
          start = ''
            exec ${dockerBin} run \
              --name krater-worker \
              --network krater \
              --env-file ${envDir}/worker.env \
              ${envArgs appEnv} \
              --restart no \
              "$(cat ${envDir}/image)" \
              procrastinate --app=krater.worker.app.app worker
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
            umask 077
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
      # With compute on, rented machines call the portal's runner API (/runner/v1/) and the storage
      # hostname: never put either behind a browser challenge.
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
              };
              services = {
                krater = backend cfg.port;
                krater-storage = backend cfg.storage.port;
              };
            };
          };
      })
    ]
  );
}
