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
  skipBackupFile = "${stateDir}/skip-backup";
  # owner/name of `repo` on GitHub, for the check-runs API. null for another host.
  githubSlug =
    let
      m = builtins.match "https://github\\.com/([^/]+/[^/.]+)(\\.git)?/?" cfg.repo;
    in
    if m == null then null else builtins.head m;
  envDir = "/run/${prefix}";

  # Exits 3 when the database is at a migration this image does not have: a newer release ran
  # it, and this is an older one starting again (a failed deploy, a revert). Migrations only add
  # (Krater's docs/dev/production.md), so the older code can run on that schema, but
  # `alembic upgrade head` would fail on the unknown revision.
  dbIsNewer = lib.escapeShellArg ''
    import sys
    from alembic.config import Config
    from alembic.runtime.migration import MigrationContext
    from alembic.script import ScriptDirectory
    from krater.db import get_engine
    known = {r.revision for r in ScriptDirectory.from_config(Config("alembic.ini")).walk_revisions()}
    with get_engine().connect() as c:
        current = set(MigrationContext.configure(c).get_current_heads())
    sys.exit(3 if current - known else 0)
  '';

  # The only command a CI deploy key may run (`restrict,command=` on each key). CI sends one full
  # commit SHA as the ssh command, or `ping` to check that it can log in. No shell, no forwarding.
  systemctl = "${config.systemd.package}/bin/systemctl";
  deployCommand = pkgs.writeShellScript "${prefix}-deploy" ''
    set -euo pipefail
    sha=''${SSH_ORIGINAL_COMMAND:-}
    if [ "$sha" = ping ]; then
      echo ok
      exit 0
    fi
    if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
      echo "${prefix}-deploy: send one full 40-character commit SHA" >&2
      exit 2
    fi
    # A failed build puts the old SHA back. Otherwise the next restart of ${prefix}-web (a reboot, a
    # host deploy) would build the broken commit again and the site would stay down.
    old=$(cat ${revFile} 2>/dev/null || true)
    echo "$sha" > ${revFile}
    if ! /run/wrappers/bin/sudo /run/current-system/sw/bin/systemctl start ${prefix}-build; then
      echo "$old" > ${revFile}
      echo "${prefix}-deploy: the build of $sha failed; source-rev is back at '$old'" >&2
      exit 1
    fi
    /run/wrappers/bin/sudo /run/current-system/sw/bin/systemctl restart ${prefix}-web
    # krater-worker restarts with krater-web (partOf) and can still be starting.
    for _ in $(seq 1 30); do
      if ${systemctl} is-active --quiet ${prefix}-web ${prefix}-worker; then
        ${systemctl} is-active ${prefix}-web ${prefix}-worker
        exit 0
      fi
      sleep 2
    done
    ${systemctl} is-active ${prefix}-web ${prefix}-worker
    exit 1
  '';

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
  # The store's size, for Krater's "storage 80% full" alert and its admin overview. Each volume is 1 GB. With 0
  # volumes (sized from free disk) Krater can't know it, so the variable is left out and the alert is off.
  // lib.optionalAttrs (cfg.storage.maxVolumes > 0) {
    KRATER_COMPUTE_STORE_CAPACITY_GB = toString cfg.storage.maxVolumes;
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
      stopTimeout ? null,
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
        ExecStop =
          if stopTimeout == null then
            "${dockerBin} stop ${prefix}-${name}"
          else
            "${dockerBin} stop --time ${toString stopTimeout} ${prefix}-${name}";
        Restart = "on-failure";
        RestartSec = "10s";
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "${prefix}-${name}";
      }
      // lib.optionalAttrs (timeoutStart != null) { TimeoutStartSec = timeoutStart; }
      // lib.optionalAttrs (stopTimeout != null) { TimeoutStopSec = stopTimeout + 30; };
    };

  # Pull the image, but start with the local copy when the pull fails and one is
  # there. A failed start of storage fails web and the worker for good ("Dependency
  # failed", no retry), so a registry or DNS blip at a switch must not stop it.
  pull =
    image:
    pkgs.writeShellScript "${prefix}-pull" ''
      # A bound well under the unit's 90s start timeout, so a pull that hangs on DNS still falls back.
      if ! ${pkgs.coreutils}/bin/timeout 45 ${dockerBin} pull ${lib.escapeShellArg image}; then
        if ${dockerBin} image inspect ${lib.escapeShellArg image} >/dev/null 2>&1; then
          echo "${prefix}: pull of ${image} failed; starting the local copy" >&2
        else
          exit 1
        fi
      fi
    '';

  # ── Blue/green portal (blueGreen.enable) ───────────────────────────────────
  # ${prefix}-web is then a oneshot that makes the release in source-rev the one serving, with no
  # gap: it migrates while the running container keeps serving (Krater's migrations only add, so the
  # running release works on the newer schema), starts the new release in the idle slot (blue on
  # `port`, green on `blueGreen.standbyPort`), waits for its /healthz to answer 200, points nginx at it
  # (`blueGreen.upstreamFile`, then a reload, which lets requests in flight finish), and only then
  # stops the old container, giving uvicorn 30 s to finish its requests. A release that never gets
  # healthy is removed and the old one keeps serving. Run again with the same release (a reboot,
  # a second restart), it changes nothing. The containers are Docker's (--restart unless-stopped),
  # not systemd units, so a restart of this unit never stops the one serving.
  activeFile = "${stateDir}/active-slot";
  # The follow timer's health check: the serving slot's port, read at run time under blue/green.
  healthPort = if cfg.blueGreen.enable then "$port" else toString cfg.port;
  slotPort = slot: if slot == "blue" then cfg.port else cfg.blueGreen.standbyPort;
  converge = pkgs.writeShellApplication {
    name = "${prefix}-web-converge";
    runtimeInputs = [
      config.virtualisation.docker.package
      config.systemd.package
      pkgs.coreutils
      pkgs.curl
      pkgs.util-linux
    ];
    text = ''
      exec 9> /run/${prefix}-web-converge.lock
      flock 9
      ${resolveImage}
      if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "${prefix}: $image isn't built; run: systemctl start ${prefix}-build" >&2
        exit 1
      fi
      ${writeAppEnv}
      ${writeWebEnv}

      port_of() {
        if [ "$1" = blue ]; then echo ${toString (slotPort "blue")}; else echo ${toString (slotPort "green")}; fi
      }
      running() {
        [ "$(docker inspect --format '{{.State.Running}}' "${prefix}-web-$1" 2>/dev/null)" = true ]
      }
      healthy() {
        curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$(port_of "$1")/healthz"
      }
      # Points nginx at a slot. The file survives a reboot; nginx reads it at start and on reload.
      serve() {
        want="server 127.0.0.1:$(port_of "$1");"
        if [ "$(cat ${cfg.blueGreen.upstreamFile} 2>/dev/null)" != "$want" ]; then
          echo "$want" > ${cfg.blueGreen.upstreamFile}.new
          chmod 0644 ${cfg.blueGreen.upstreamFile}.new
          mv ${cfg.blueGreen.upstreamFile}.new ${cfg.blueGreen.upstreamFile}
          systemctl try-reload-or-restart ${cfg.blueGreen.proxyUnit}
        fi
        echo "$1" > ${activeFile}
      }

      # The one container from before blue/green (stopped by its old unit) holds no port, but its name
      # would confuse `docker ps`.
      docker rm -f ${prefix}-web >/dev/null 2>&1 || true

      active=$(cat ${activeFile} 2>/dev/null || true)
      if [ "$active" != blue ] && [ "$active" != green ]; then
        active=""
      fi
      if [ -n "$active" ] && running "$active" \
        && [ "$(docker inspect --format '{{.Config.Image}}' "${prefix}-web-$active")" = "$image" ] \
        && healthy "$active"; then
        serve "$active"
        echo "$image" > ${envDir}/image
        echo "${prefix}: $image already serves from the $active slot"
        exit 0
      fi
      if [ "$active" = blue ]; then new=green; else new=blue; fi

      # Settings first, so a wrong value fails at once with Krater's message.
      if ! docker run --rm \
        --network ${prefix} \
        ${hostArgs} \
        --env-file ${envDir}/app.env \
        ${envArgs appEnv} \
        "$image" \
        python -c 'from krater.config import get_settings; get_settings()'; then
        echo "${prefix}: the settings are not valid (see the error above). Fix ${cfg.environmentFile} or the module options." >&2
        exit 1
      fi
      echo "Waiting for the database..."
      until docker run --rm \
        --network ${prefix} \
        ${hostArgs} \
        --env-file ${envDir}/app.env \
        ${envArgs appEnv} \
        "$image" \
        python -c 'from krater.db import get_engine; get_engine().connect().close()'; do
        sleep 5
      done
      # Migrations (they only add, so the release serving now keeps working), then the bucket and its
      # CORS rule. An older release on a database a newer one migrated starts without migrating.
      # shellcheck disable=SC2016
      docker run --rm \
        --network ${prefix} \
        ${hostArgs} \
        --env-file ${envDir}/app.env \
        ${envArgs appEnv} \
        "$image" \
        sh -c 'python -c "$1"; s=$?
          if [ "$s" = 3 ]; then echo "The database is at a newer migration than this release; starting without migrating."
          elif [ "$s" = 0 ]; then alembic upgrade head || exit 1
          else exit "$s"; fi
          python -m krater.storage.ensure_bucket' sh ${dbIsNewer}

      echo "${prefix}: starting $image in the $new slot (port $(port_of "$new"))"
      docker rm -f "${prefix}-web-$new" >/dev/null 2>&1 || true
      docker run --detach \
        --name "${prefix}-web-$new" \
        --network ${prefix} \
        ${hostArgs} \
        --publish "127.0.0.1:$(port_of "$new"):8000" \
        --env-file ${envDir}/web.env \
        ${envArgs appEnv} \
        --restart unless-stopped \
        --log-driver journald \
        --log-opt tag=${prefix}-web \
        "$image" >/dev/null
      # An HTTP 200, not an open port: Docker's proxy takes connections before uvicorn listens.
      ok=""
      for _ in $(seq 1 90); do
        if healthy "$new"; then
          ok=1
          break
        fi
        if ! running "$new"; then
          break
        fi
        sleep 2
      done
      if [ -z "$ok" ]; then
        docker logs --tail 60 "${prefix}-web-$new" >&2 || true
        docker rm -f "${prefix}-web-$new" >/dev/null 2>&1 || true
        echo "${prefix}: $image did not answer /healthz; ''${active:-nothing} keeps serving" >&2
        exit 1
      fi

      serve "$new"
      echo "$image" > ${envDir}/image
      echo "${prefix}: $image serves from the $new slot"
      # The reload keeps nginx's old workers until the requests they hold are done; give those a moment,
      # then let uvicorn finish what it has (SIGTERM, 30 s) before the old release goes.
      if [ "$new" = blue ]; then old=green; else old=blue; fi
      if docker inspect "${prefix}-web-$old" >/dev/null 2>&1; then
        sleep 5
        docker stop --time 30 "${prefix}-web-$old" >/dev/null || true
        docker rm -f "${prefix}-web-$old" >/dev/null 2>&1 || true
        echo "${prefix}: stopped the $old slot"
      fi
    '';
  };

  blueGreenWeb = {
    description = "Krater web: serve the release in source-rev (blue/green)";
    after = [
      "docker.service"
      "${prefix}-network.service"
      "${prefix}-build.service"
      "${prefix}-storage.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [
      "docker.service"
      "${prefix}-network.service"
      "${prefix}-build.service"
      "${prefix}-storage.service"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Waiting for the database, migrations and the new release's start.
      TimeoutStartSec = "15min";
      ExecStart = lib.getExe converge;
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = "${prefix}-web";
    };
  };
in
{
  options.patchwork.services.${optName} = {
    enable = lib.mkEnableOption "Krater, the Project Ganymede portal";

    repo = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/patchworklabsorg/krater.git";
      description = "Git repository krater-build fetches the source from. Must be readable without credentials.";
    };

    registry = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "ghcr.io/patchworklabsorg/krater";
      description = ''
        Where Krater's CI pushes the image of each commit on main, as <registry>:<full sha>. ${prefix}-build
        pulls it from here, and builds from `repo` only when the pull fails (an older commit, the registry
        down). The image must carry the label org.patchworklabs.krater.rev=<sha>. Pulled without
        credentials, so the package must be public. null always builds from source.
      '';
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
        SSH public keys for the ${prefix}-deploy CI user. Each key may run only the deploy command:
        `ssh ${prefix}-deploy@<host> <full commit SHA>` writes /var/lib/${prefix}/source-rev, then runs
          sudo systemctl start ${prefix}-build
          sudo systemctl restart ${prefix}-web
        and waits for the portal and the worker. `ssh ... ping` only checks the login. No shell, no
        forwarding (`restrict`).
      '';
    };

    backup = {
      beforeDeploy = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Dump the database schema (`schema`) to `dir` with ${prefix}-backup before each follow
          deploy restarts the portal (which migrates). A failed dump fails the deploy; touch
          ${stateDir}/skip-backup to deploy once without one. Run a dump by hand with
          `systemctl start ${prefix}-backup`. Restore on the database host with
          `pg_restore --clean --if-exists --schema=<schema> -d <database> <file>`. pg_dump is
          PostgreSQL 18, the version of modules/central-db: it refuses a newer server.
        '';
      };
      schema = lib.mkOption {
        type = lib.types.str;
        default = "krater";
        description = "The schema to dump: the database role's own schema.";
      };
      dir = lib.mkOption {
        type = lib.types.str;
        default = "${stateDir}/backups";
        description = "Where the dumps go (pg_dump custom format, root only).";
      };
      keep = lib.mkOption {
        type = lib.types.ints.positive;
        default = 14;
        description = "How many dumps to keep (one per deploy, not per day). Older ones are deleted after each new dump.";
      };
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
      ancestorOf = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "main";
        description = ''
          Deploy a commit only when it is on this branch of `repo` too (the GitHub compare API).
          With "main", a commit pushed only to a feature branch never deploys, even with green
          checks. Needs `repo` on github.com.
        '';
      };
      dates = lib.mkOption {
        type = lib.types.str;
        default = "*:0/5";
        description = "When to check the branch (systemd OnCalendar).";
      };
    };

    blueGreen = {
      enable = lib.mkEnableOption ''
        deploys with no gap: ${prefix}-web starts each release beside the running one and switches the
        reverse proxy to it once it answers /healthz (see "Blue/green portal" in this module). The proxy
        must send the portal's traffic to `upstream ${prefix}-web { include <upstreamFile>; }`
      '';
      standbyPort = lib.mkOption {
        type = lib.types.port;
        default = defaultPort + 10;
        description = "Loopback host port of the second (green) slot; the first (blue) is `port`.";
      };
      upstreamFile = lib.mkOption {
        type = lib.types.str;
        default = "${stateDir}/nginx-upstream.conf";
        readOnly = true;
        description = "The `server` line of the slot serving now, for an nginx upstream block to include.";
      };
      proxyUnit = lib.mkOption {
        type = lib.types.str;
        default = "nginx.service";
        description = "The reverse proxy, reloaded after each switch.";
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
              assertion =
                cfg.follow.branch != null && (cfg.follow.requireChecks || cfg.follow.ancestorOf != null)
                -> githubSlug != null;
              message = "patchwork.services.${optName}.follow.requireChecks needs `repo` on https://github.com";
            }
            {
              # The Traefik fragment routes to `port`, which serves only while the blue slot does.
              assertion = cfg.blueGreen.enable -> !cfg.traefik.enable;
              message = "patchwork.services.${optName}.blueGreen needs nginx (upstreamFile), not the traefik fragment";
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
        ++ lib.optionals cfg.blueGreen.enable [
          # nginx needs it to start; the first deploy writes the slot it starts.
          "f ${cfg.blueGreen.upstreamFile} 0644 root root - server 127.0.0.1:${toString cfg.port};"
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
        # while the old containers keep serving. It pulls CI's image first (`registry`): builds
        # here starved weft, and both sites stopped answering for minutes (2026-11-12). A build from
        # source is the fallback, for commits CI never pushed.
        systemd.services."${prefix}-build" = {
          description = "Pull or build the ${prefix} image";
          after = [
            "docker.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          requires = [ "docker.service" ];
          path = [
            pkgs.git
            pkgs.util-linux
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
            # This unit's own processes (git, the pull) only: the build itself runs in the Docker
            # daemon.
            Nice = 19;
            IOSchedulingClass = "idle";
          };
          script = ''
            set -euo pipefail
            ${resolveImage}
            if docker image inspect "$image" >/dev/null 2>&1; then
              echo "${prefix}: $image is already built"
            ${lib.optionalString (cfg.registry != null) ''
              elif ${pkgs.coreutils}/bin/timeout 10m docker pull ${lib.escapeShellArg cfg.registry}:"$rev"; then
                # CI's image of this commit, if it says so: then it is $image.
                label=$(docker image inspect --format '{{ index .Config.Labels "org.patchworklabs.krater.rev" }}' ${lib.escapeShellArg cfg.registry}:"$rev")
                if [ "$label" = "$rev" ]; then
                  docker tag ${lib.escapeShellArg cfg.registry}:"$rev" "$image"
                  echo "${prefix}: pulled $image from ${cfg.registry}"
                else
                  echo "${prefix}: ${cfg.registry}:$rev is labelled '$label', not $rev; building from source" >&2
                fi
                # Only the tag: the layers stay under $image, and the cleanup below sees one tag.
                docker rmi ${lib.escapeShellArg cfg.registry}:"$rev" >/dev/null
            ''}
            fi
            if ! docker image inspect "$image" >/dev/null 2>&1; then
              # Fetched here rather than handed to `docker build` as a git URL, which would need
              # git inside the Docker daemon's own PATH.
              src=$(mktemp -d)
              trap 'rm -rf "$src"' EXIT
              git -C "$src" init -q
              git -C "$src" fetch -q --depth 1 ${lib.escapeShellArg cfg.repo} "$rev"
              git -C "$src" checkout -q FETCH_HEAD
              # One image build at a time on the host: staging and production share its memory.
              flock /run/krater-docker-build.lock docker build --label "org.patchworklabs.krater.rev=$rev" --tag "$image" "$src"
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
        systemd.services."${prefix}-web" =
          if cfg.blueGreen.enable then
            blueGreenWeb
          else
            mkContainer {
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
                  # Migrations, then the screenshot bucket and its CORS rule. Both are idempotent. An
                  # older release on a database a newer one migrated starts without migrating.
                  ${dockerBin} run --rm \
                    --network ${prefix} \
                    ${hostArgs} \
                    --env-file ${envDir}/app.env \
                    ${envArgs appEnv} \
                    "$image" \
                    sh -c 'python -c "$1"; s=$?
                      if [ "$s" = 3 ]; then echo "The database is at a newer migration than this release; starting without migrating."
                      elif [ "$s" = 0 ]; then alembic upgrade head || exit 1
                      else exit "$s"; fi
                      python -m krater.storage.ensure_bucket' sh ${dbIsNewer}
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
          # Blue/green: a release that fails to start leaves the old one serving, and the worker must
          # come back (on the old image) rather than wait for a web unit that failed.
          requires = lib.optional (!cfg.blueGreen.enable) "${prefix}-web.service";
          wants = lib.optional cfg.blueGreen.enable "${prefix}-web.service";
          partOf = [ "${prefix}-web.service" ];
          preStart = [ writeWorkerEnv ];
          # Blue/green: time for a scheduler pass or a price check to finish before the worker stops.
          stopTimeout = if cfg.blueGreen.enable then 120 else null;
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
      # A dump of the schema, before a deploy migrates it. On this host, so not on the database
      # host's disk.
      (lib.mkIf cfg.backup.beforeDeploy {
        systemd.services."${prefix}-backup" = {
          description = "Dump the ${prefix} database schema";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [
            pkgs.coreutils
            pkgs.gnused
            pkgs.findutils
            pkgs.postgresql_18
          ];
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "15min";
            UMask = "0077";
            StandardOutput = "journal";
            StandardError = "journal";
            SyslogIdentifier = "${prefix}-backup";
          };
          script = ''
            set -euo pipefail
            # SQLAlchemy's URL (postgresql+psycopg://) as a libpq URL.
            url=$(sed -n 's/^KRATER_DATABASE_URL=//p' ${cfg.environmentFile} | tail -n 1 | tr -d '\r' \
              | sed -E 's/^postgresql\+[a-z0-9]+:/postgresql:/')
            # The password goes to libpq in a file, not on the command line where `ps` shows it.
            re='^postgresql://([^:@/]+):([^@]+)@([^:/?]+)(:([0-9]+))?/([^?]+)(\?(.*))?$'
            if ! [[ $url =~ $re ]]; then
              echo "${prefix}-backup: KRATER_DATABASE_URL in ${cfg.environmentFile} is missing or not user:password@host/db" >&2
              exit 1
            fi
            decode() { printf '%b' "''${1//%/\\x}"; }
            export PGUSER PGHOST PGPORT PGDATABASE
            PGUSER=$(decode "''${BASH_REMATCH[1]}")
            pass=$(decode "''${BASH_REMATCH[2]}")
            PGHOST=''${BASH_REMATCH[3]}
            PGPORT=''${BASH_REMATCH[5]:-5432}
            PGDATABASE=$(decode "''${BASH_REMATCH[6]}")
            if [[ ''${BASH_REMATCH[8]} =~ (^|&)sslmode=([a-z-]+) ]]; then export PGSSLMODE=''${BASH_REMATCH[2]}; fi
            # The host may have no DNS for the database host (extraHosts).
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: ip: ''
                if [ "$PGHOST" = ${lib.escapeShellArg name} ]; then export PGHOSTADDR=${lib.escapeShellArg ip}; fi
              '') cfg.extraHosts
            )}
            export PGPASSFILE=$(mktemp)
            install -d -m 0700 ${cfg.backup.dir}
            file=${cfg.backup.dir}/${cfg.backup.schema}-$(date -u +%Y%m%dT%H%M%SZ).dump
            trap 'rm -f "$PGPASSFILE" "$file.partial"' EXIT
            # pgpass escapes : and \ in each field.
            esc() { local v=''${1//\\/\\\\}; printf '%s' "''${v//:/\\:}"; }
            printf '*:*:*:*:%s\n' "$(esc "$pass")" > "$PGPASSFILE"
            pg_dump --format=custom --schema=${lib.escapeShellArg cfg.backup.schema} --file="$file.partial"
            mv "$file.partial" "$file"
            echo "${prefix}-backup: $file ($(du -h "$file" | cut -f1))"
            # Newest first; delete all after the first ${toString cfg.backup.keep}.
            ls -1t ${cfg.backup.dir}/*.dump | tail -n +${toString (cfg.backup.keep + 1)} | xargs -r rm -f
          '';
        };
      })

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
            ${lib.optionalString (cfg.follow.ancestorOf != null) ''
              # "behind" or "identical": $remote is on ${cfg.follow.ancestorOf}.
              onBranch=$(curl -fsS -H 'Accept: application/vnd.github+json' \
                "https://api.github.com/repos/${toString githubSlug}/compare/${cfg.follow.ancestorOf}...$remote" \
                | jq -r '.status')
              if [ "$onBranch" != behind ] && [ "$onBranch" != identical ]; then
                echo "$remote is not on ${cfg.follow.ancestorOf} ($onBranch); not deploying it" >&2
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
            ${lib.optionalString cfg.backup.beforeDeploy ''
              # A dump just before the restart, which migrates the database. A failed dump counts
              # as a failed deploy (3 tries). ${skipBackupFile} skips the dump for one deploy.
              if [ -e ${skipBackupFile} ]; then
                rm -f ${skipBackupFile}
                echo "WARNING: $remote deploys with NO database dump (${skipBackupFile} was set)" >&2
              elif ! systemctl start ${prefix}-backup; then
                restore
                failed
                echo "$remote: the database dump failed; not deploying it. To deploy without one: touch ${skipBackupFile}" >&2
                exit 1
              fi
            ''}
            if ! systemctl restart ${prefix}-web; then
              # The old container is gone already, so start the old version again.
              restore
              failed
              echo "$remote did not start; starting ''${current:-${cfg.rev}} again" >&2
              systemctl restart ${prefix}-web || true
              exit 1
            fi
            # The worker restarts with web (partOf). /healthz/worker answers 200 only while the
            # worker beats, so both answering 200 means the new version runs.
            ${lib.optionalString cfg.blueGreen.enable ''
              # Blue/green: the slot ${prefix}-web just made the one serving.
              if [ "$(cat ${activeFile} 2>/dev/null)" = green ]; then port=${toString cfg.blueGreen.standbyPort}; else port=${toString cfg.port}; fi
            ''}
            for _ in $(seq 1 60); do
              sleep 2
              if curl -fsS -o /dev/null http://127.0.0.1:${healthPort}/healthz \
                && curl -fsS -o /dev/null http://127.0.0.1:${healthPort}/healthz/worker; then
                echo "$remote is live"
                exit 0
              fi
            done
            restore
            failed
            echo "$remote did not stay up; starting ''${current:-${cfg.rev}} again" >&2
            systemctl restart ${prefix}-web || true
            exit 1
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
          openssh.authorizedKeys.keys = map (
            key: ''restrict,command="${deployCommand}" ${key}''
          ) cfg.deployAuthorizedKeys;
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
