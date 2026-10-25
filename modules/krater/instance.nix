# One Krater instance. ./default.nix imports this twice: staging
# (patchwork.services.krater, names krater-*) and production
# (patchwork.services.krater-production, names krater-prod-*). Each instance has
# its own units, Docker network, image repository, state and run directories,
# loopback ports and CI deploy user, so the two can run on one host.
{
  # The option path under patchwork.services, and the prefix of every name.
  optName,
  prefix,
  defaultPort,
  defaultStoragePort,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork.services.${optName};
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";

  stateDir = "/var/lib/${prefix}";
  secretsDir = "${stateDir}/secrets";
  revFile = "${stateDir}/source-rev";
  deployUser = "${prefix}-deploy";
  followFailedFile = "${stateDir}/follow-failed-rev";
  followMaxAttempts = 3;
  followHoldFile = "${stateDir}/follow-hold";
  # owner/name of `repo` on GitHub, for the check-runs API. null for another host.
  githubSlug =
    let
      m = builtins.match "https://github\\.com/([^/]+/[^/.]+)(\\.git)?/?" cfg.repo;
    in
    if m == null then null else builtins.head m;
  envDir = "/run/${prefix}";

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
    KRATER_S3_ENDPOINT_URL = "http://${prefix}-storage:8333";
    KRATER_S3_PUBLIC_ENDPOINT_URL = "https://${cfg.storage.domain}";
  }
  // lib.optionalAttrs cfg.compute.enable {
    KRATER_VAST_MODE = "live";
    # The scheduler destroys unknown instances with this prefix: unique per deployment on one Vast account.
    # Never null here: an assertion requires it when compute is on.
    KRATER_COMPUTE_LABEL_PREFIX = toString cfg.compute.labelPrefix;
    KRATER_COMPUTE_RUNNER_URL = cfg.compute.runnerUrl;
  }
  // lib.optionalAttrs (cfg.weave.cliClientId != "") {
    KRATER_WEAVE_CLI_CLIENT_ID = cfg.weave.cliClientId;
  }
  // cfg.extraEnv;

  # --add-host for each extraHosts entry: the containers are on the `krater` bridge network, so
  # Docker's DNS answers them from the host's resolvers, not from /etc/hosts.
  hostArgs = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: ip: "--add-host ${lib.escapeShellArg "${name}:${ip}"}") cfg.extraHosts
  );

  envArgs =
    env:
    lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"}") env);

  # Writes /run/<prefix>/<name>.env with only the listed keys of the env file, renamed `from` -> `to`.
  writeEnvScript =
    name: pairs:
    pkgs.writeShellScript "${prefix}-${name}-env" ''
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

  # The portal and worker get every KRATER_ key of the env file, the database URL among them.
  writeAppEnv = pkgs.writeShellScript "${prefix}-app-env" ''
    set -euo pipefail
    install -d -m 0700 ${envDir}
    umask 077
    if ! grep -q '^KRATER_DATABASE_URL=.' ${cfg.environmentFile}; then
      echo "krater: KRATER_DATABASE_URL is missing from ${cfg.environmentFile}" >&2
      exit 1
    fi
    grep -E '^KRATER_' ${cfg.environmentFile} > ${envDir}/app.env
  '';

  # The portal's env: app.env plus the project-secrets keys (comma-separated, newest first).
  writeWebEnv = pkgs.writeShellScript "${prefix}-web-env" ''
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
  writeWorkerEnv = pkgs.writeShellScript "${prefix}-worker-env" ''
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
      echo "${prefix}: '$rev' is not a full 40-character commit SHA (${revFile})" >&2
      exit 1
    fi
    image="${prefix}:$rev"
  '';

  # A `docker run` container as a systemd service, in the style of the Weave module: the unit owns the
  # container's lifecycle (`--restart no`, systemd restarts it).
  mkContainer =
    {
      name,
      description,
      after ? [ ],
      wants ? [ ],
      requires ? [ ],
      partOf ? [ ],
      preStart ? [ ],
      start,
      timeoutStart ? null,
    }:
    {
      inherit description partOf wants;
      after = [
        "docker.service"
        "${prefix}-network.service"
      ]
      ++ after;
      requires = [
        "docker.service"
        "${prefix}-network.service"
      ]
      ++ requires;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          "-${dockerBin} stop ${prefix}-${name}"
          "-${dockerBin} rm ${prefix}-${name}"
        ]
        ++ preStart;
        ExecStart = pkgs.writeShellScript "${prefix}-${name}-start" start;
        ExecStop = "${dockerBin} stop ${prefix}-${name}";
        Restart = "on-failure";
        RestartSec = "10s";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "${prefix}-${name}";
      }
      // lib.optionalAttrs (timeoutStart != null) { TimeoutStartSec = timeoutStart; };
    };

  pull = image: "${dockerBin} pull ${image}";
in
{
  options.patchwork.services.${optName} = {
    enable = lib.mkEnableOption "Krater, the Project Ganymede portal";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/patchworklabsorg/krater.git";
      description = "Git repository krater-build fetches the source from. Must be readable without credentials.";
    };

    rev = lib.mkOption {
      type = lib.types.strMatching "[0-9a-f]{40}";
      description = ''
        Fallback commit (full SHA) to build when /var/lib/${prefix}/source-rev is empty. Deploys write
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
      default = defaultPort;
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
        default = defaultStoragePort;
        description = "Loopback host port for the S3 gateway.";
      };
      image = lib.mkOption {
        type = lib.types.str;
        default = "chrislusf/seaweedfs:4.47";
        description = "SeaweedFS image. 4.47 is the version Krater's staging ran; bump it only after a staging run.";
      };
      maxVolumes = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          The most 1 GB SeaweedFS volumes the store may make (-volume.max). This caps the bucket's disk use.
          0 sizes the limit from free disk, which lets the store fill the host's disk.
        '';
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
        type = lib.types.nullOr (lib.types.strMatching "[a-z0-9-]+-");
        default = null;
        example = "krater-staging-";
        description = ''
          Required when compute.enable is true.
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

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        KRATER_BUDGET_WARN_PERCENT = "80";
      };
      description = "Extra non-secret settings for the portal, worker and migrations.";
    };

    extraHosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "hem.wildebeest-stargazer.ts.net" = "100.67.124.123";
      };
      description = ''
        Host name to address entries for the portal, the worker and the migrations (`--add-host`).
        For a database host name that the host's DNS cannot resolve, such as a tailnet name on a
        host without MagicDNS.
      '';
    };

    deployAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys for the ${prefix}-deploy CI user. That user may write
        /var/lib/${prefix}/source-rev and run only:
          sudo systemctl start ${prefix}-build
          sudo systemctl restart ${prefix}-web
      '';
    };

    follow = {
      branch = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "main";
        description = ''
          Deploy each new commit on this branch of `repo` with no action by hand. A timer
          (${prefix}-follow) reads the head of the branch. When it is new, it writes source-rev,
          builds and restarts ${prefix}-web: the same steps as a CI deploy. null turns it off.
        '';
      };
      requireChecks = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Deploy a commit only after all of its GitHub check runs passed. A commit with no check
          runs waits. Needs `repo` on github.com.
        '';
      };
      dates = lib.mkOption {
        type = lib.types.str;
        default = "*:0/5";
        description = "When to check the branch (systemd OnCalendar).";
      };
    };

    traefik = {
      enable = lib.mkEnableOption ''
        a Traefik file-provider fragment (/etc/traefik/conf.d/${prefix}.toml) routing the portal and
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
              message = "patchwork.services.${optName}.weave.${name} must be set";
            })
            [
              "issuer"
              "clientId"
            ]
          ++ [
            {
              assertion = cfg.compute.enable -> cfg.compute.vastKeyFile != null;
              message = "patchwork.services.${optName}.compute.vastKeyFile must be set when compute.enable is true";
            }
            {
              assertion = cfg.follow.branch != null && cfg.follow.requireChecks -> githubSlug != null;
              message = "patchwork.services.${optName}.follow.requireChecks needs `repo` on https://github.com";
            }
            {
              assertion = cfg.compute.enable -> cfg.compute.labelPrefix != null;
              message = "patchwork.services.${optName}.compute.labelPrefix must be set when compute.enable is true";
            }
          ];

        # ── State ───────────────────────────────────────────────────────────────
        # /var/lib/<prefix> itself stays 0755 (as in the Weave module) so the deploy user can reach
        # source-rev. Secrets hold tokens: root only.
        systemd.tmpfiles.rules = [
          "d ${secretsDir} 0700 root root -"
        ]
        ++ lib.optionals (cfg.deployAuthorizedKeys != [ ]) [
          "f ${revFile} 0644 ${deployUser} users -"
          "z ${revFile} 0644 ${deployUser} users -"
        ];

        # ── Docker network ──────────────────────────────────────────────────────
        systemd.services."${prefix}-network" = {
          description = "Create the ${prefix} Docker network";
          after = [ "docker.service" ];
          requires = [ "docker.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # Not secrets/: StateDirectoryMode is reapplied on every start, and it stays 0700 (tmpfiles
            # rule above).
            StateDirectory = "${prefix} ${prefix}/storage";
            StateDirectoryMode = "0755";
            ExecStart = pkgs.writeShellScript "${prefix}-network-create" ''
              ${dockerBin} network inspect ${prefix} >/dev/null 2>&1 || \
                ${dockerBin} network create ${prefix}
            '';
          };
        };

        # ── Image build ─────────────────────────────────────────────────────────
        # A oneshot of its own, not part of krater-web's start: the first build of the Python
        # dependencies takes minutes, far past a service's start timeout, and a deploy can run it
        # while the old containers keep serving.
        systemd.services."${prefix}-build" = {
          description = "Build the ${prefix} image from source";
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
          # A switch must not stop a build that a deploy waits for. The next start uses the new
          # unit anyway.
          restartIfChanged = false;
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "45min";
            StandardOutput = "journal";
            StandardError = "journal";
            SyslogIdentifier = "${prefix}-build";
          };
          script = ''
            set -euo pipefail
            ${resolveImage}
            if docker image inspect "$image" >/dev/null 2>&1; then
              echo "${prefix}: $image is already built"
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
            docker image ls ${prefix} --format '{{.Tag}}' | { grep -vx "$rev" || true; } | while read -r tag; do
              docker rmi "${prefix}:$tag" >/dev/null 2>&1 || true
            done
            # BuildKit's cache (the dependency layers) grows with each build. Keep one week of it.
            docker builder prune -f --filter until=168h >/dev/null || true
          '';
        };

        # ── Screenshot storage (SeaweedFS) ──────────────────────────────────────
        systemd.services."${prefix}-storage" = mkContainer {
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
              --name ${prefix}-storage \
              --network ${prefix} \
              --publish 127.0.0.1:${toString cfg.storage.port}:8333 \
              --env-file ${envDir}/storage.env \
              --env VOLUME_MAX=${toString cfg.storage.maxVolumes} \
              --volume ${stateDir}/storage:/data \
              --volume ${./storage-start.sh}:/krater/storage-start.sh:ro \
              --entrypoint /bin/sh \
              --restart no \
              ${cfg.storage.image} /krater/storage-start.sh
          '';
        };

        # ── Portal ──────────────────────────────────────────────────────────────
        systemd.services."${prefix}-web" = mkContainer {
          name = "web";
          description = "Krater web";
          after = [
            "${prefix}-build.service"
            "${prefix}-storage.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          requires = [
            "${prefix}-build.service"
            "${prefix}-storage.service"
          ];
          # Waiting for the database and running migrations can outlast the default 90s.
          timeoutStart = "10min";
          preStart = [
            (pkgs.writeShellScript "${prefix}-web-prepare" ''
              set -euo pipefail
              ${resolveImage}
              if ! ${dockerBin} image inspect "$image" >/dev/null 2>&1; then
                echo "${prefix}: $image isn't built; run: systemctl start ${prefix}-build" >&2
                exit 1
              fi
              ${writeAppEnv}
              ${writeWebEnv}
              echo "$image" > ${envDir}/image

              # Check the settings first, so a wrong or missing value in the env file fails the
              # unit at once with Krater's message, not after a long wait for the database.
              if ! ${dockerBin} run --rm \
                --network ${prefix} \
                ${hostArgs} \
                --env-file ${envDir}/app.env \
                ${envArgs appEnv} \
                "$image" \
                python -c 'from krater.config import get_settings; get_settings()'; then
                echo "${prefix}: the settings are not valid (see the error above). Fix ${cfg.environmentFile} or the module options." >&2
                exit 1
              fi

              # The database is on another host (patchwork_central): wait until a connection works,
              # from a container like the portal's, so DNS and routing are tested the same way.
              echo "Waiting for the database..."
              until ${dockerBin} run --rm \
                --network ${prefix} \
                ${hostArgs} \
                --env-file ${envDir}/app.env \
                ${envArgs appEnv} \
                "$image" \
                python -c 'from krater.db import get_engine; get_engine().connect().close()'; do
                sleep 5
              done
              # Migrations, then the screenshot bucket and its CORS rule. Both are idempotent.
              ${dockerBin} run --rm \
                --network ${prefix} \
                ${hostArgs} \
                --env-file ${envDir}/app.env \
                ${envArgs appEnv} \
                "$image" \
                sh -c 'alembic upgrade head && python -m krater.storage.ensure_bucket'
            '')
          ];
          start = ''
            exec ${dockerBin} run \
              --name ${prefix}-web \
              --network ${prefix} \
              ${hostArgs} \
              --publish 127.0.0.1:${toString cfg.port}:8000 \
              --env-file ${envDir}/web.env \
              ${envArgs appEnv} \
              --restart no \
              "$(cat ${envDir}/image)"
          '';
        };

        # ── Worker ──────────────────────────────────────────────────────────────
        systemd.services."${prefix}-worker" = mkContainer {
          name = "worker";
          description = "Krater worker (procrastinate)";
          # Runs the image and env krater-web just prepared, after its migrations. partOf carries a
          # deploy's `restart krater-web` over to the worker, as in the Weave module. Two tasks at a time, so
          # the minute's compute scheduler pass never waits behind the slow price-history run.
          after = [ "${prefix}-web.service" ];
          requires = [ "${prefix}-web.service" ];
          partOf = [ "${prefix}-web.service" ];
          preStart = [ writeWorkerEnv ];
          start = ''
            exec ${dockerBin} run \
              --name ${prefix}-worker \
              --network ${prefix} \
              ${hostArgs} \
              --env-file ${envDir}/worker.env \
              ${envArgs appEnv} \
              --restart no \
              "$(cat ${envDir}/image)" \
              procrastinate --app=krater.worker.app.app worker --concurrency=2
          '';
        };
      }

      # ── Follow a branch ─────────────────────────────────────────────────────
      # The deploy above, run from a timer on this host: nothing outside needs a way in. A
      # build or a start that fails puts the old source-rev back and starts the old version
      # again. A commit gets ${toString followMaxAttempts} tries, then waits for a new commit
      # (${followFailedFile}; remove it to try again). A manual deploy of another commit holds
      # only until the next run. To keep it, create ${followHoldFile} first.
      (lib.mkIf (cfg.follow.branch != null) {
        systemd.services."${prefix}-follow" = {
          description = "Deploy the head of ${cfg.follow.branch} to ${prefix}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          # A switch must not stop a deploy in the middle of its build.
          restartIfChanged = false;
          path = [
            pkgs.coreutils
            pkgs.curl
            pkgs.git
            pkgs.jq
            config.systemd.package
          ];
          serviceConfig = {
            Type = "oneshot";
            # The build can take 45 minutes (${prefix}-build).
            TimeoutStartSec = "1h";
            StandardOutput = "journal";
            StandardError = "journal";
            SyslogIdentifier = "${prefix}-follow";
          };
          script = ''
            set -euo pipefail
            if [ -e ${followHoldFile} ]; then
              echo "held: ${followHoldFile} exists"
              exit 0
            fi
            remote=$(git ls-remote ${lib.escapeShellArg cfg.repo} ${lib.escapeShellArg "refs/heads/${cfg.follow.branch}"} | cut -f1)
            if ! [[ $remote =~ ^[0-9a-f]{40}$ ]]; then
              echo "cannot read the head of ${cfg.follow.branch}" >&2
              exit 1
            fi
            current=$(tr -d '[:space:]' < ${revFile} 2>/dev/null || true)
            if [ "''${current:-${cfg.rev}}" = "$remote" ]; then
              exit 0
            fi
            # "<sha> <failed runs>". A build can fail for a short time (network, memory).
            read -r failedRev failedRuns 2>/dev/null < ${followFailedFile} || true
            if [ "''${failedRev:-}" = "$remote" ] && [ "''${failedRuns:-0}" -ge ${toString followMaxAttempts} ]; then
              echo "$remote failed ${toString followMaxAttempts} times; waiting for a new commit on ${cfg.follow.branch}" >&2
              exit 1
            fi
            failed() {
              runs=1
              if [ "''${failedRev:-}" = "$remote" ]; then
                runs=$((''${failedRuns:-0} + 1))
              fi
              echo "$remote $runs" > ${followFailedFile}
            }
            # Back to the commit that ran before. An empty source-rev means the `rev` fallback.
            restore() {
              if [ -n "$current" ]; then
                echo "$current" > ${revFile}
              else
                : > ${revFile}
              fi
            }
            ${lib.optionalString cfg.follow.requireChecks ''
              checks=$(curl -fsS -H 'Accept: application/vnd.github+json' \
                "https://api.github.com/repos/${toString githubSlug}/commits/$remote/check-runs?per_page=100" \
                | jq -r '
                    if .total_count == 0 or any(.check_runs[]; .status != "completed") then "pending"
                    elif all(.check_runs[]; .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "success"
                    else "failure" end')
              if [ "$checks" = pending ]; then
                echo "$remote: checks are not done yet"
                exit 0
              fi
              # Not recorded in ${followFailedFile}: a check that is run again and passes
              # deploys the commit on the next run.
              if [ "$checks" != success ]; then
                echo "$remote: a check failed; not deploying it" >&2
                exit 1
              fi
            ''}
            echo "deploying $remote (was ''${current:-${cfg.rev}})"
            echo "$remote" > ${revFile}
            if ! systemctl start ${prefix}-build; then
              restore
              failed
              echo "$remote did not build; the running version stays" >&2
              exit 1
            fi
            if ! systemctl restart ${prefix}-web; then
              # The old container is gone already, so start the old version again.
              restore
              failed
              echo "$remote did not start; starting ''${current:-${cfg.rev}} again" >&2
              systemctl restart ${prefix}-web || true
              exit 1
            fi
          '';
        };

        systemd.timers."${prefix}-follow" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.follow.dates;
            RandomizedDelaySec = "1min";
          };
        };
      })

      # ── CI deploy user ──────────────────────────────────────────────────────────
      (lib.mkIf (cfg.deployAuthorizedKeys != [ ]) {
        users.users.${deployUser} = {
          isNormalUser = true;
          group = "users";
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = cfg.deployAuthorizedKeys;
        };
        security.sudo.extraRules = [
          {
            users = [ deployUser ];
            commands = [
              {
                command = "/run/current-system/sw/bin/systemctl start ${prefix}-build";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl restart ${prefix}-web";
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
        environment.etc."traefik/conf.d/${prefix}.toml".source =
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
          (pkgs.formats.toml { }).generate "${prefix}.toml" {
            http = {
              routers = {
                ${prefix} = router cfg.domain prefix;
                "${prefix}-storage" = router cfg.storage.domain "${prefix}-storage";
              };
              services = {
                ${prefix} = backend cfg.port;
                "${prefix}-storage" = backend cfg.storage.port;
              };
            };
          };
      })
    ]
  );
}
