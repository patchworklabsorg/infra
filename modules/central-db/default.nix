# One PostgreSQL cluster that holds one central database (patchwork_central or
# patchwork_central_restricted). Works on a host and inside a NixOS container,
# so hem can run the two staging clusters side by side on different ports.
#
# ACCESS MODEL
#   - The database is owned by <database>_admin, a NOLOGIN role. No app owns it.
#   - Each app in `apps` gets a LOGIN role and a schema of the same name, and
#     owns that schema. The app runs its own migrations there. search_path is
#     set to its schema.
#   - Each schema in `sharedSchemas` (for example `people`) is owned by one
#     app, which runs its migrations. Two NOLOGIN group roles, <schema>_read
#     and <schema>_write, carry the grants. Apps get them through `read` and
#     `write` in their `apps` entry. Default privileges cover tables the owner
#     creates later.
#   - PUBLIC has no CONNECT on the database and no CREATE on `public`.
#
# This module never creates tables. Apps own their schemas' contents.
#
# Passwords: one file per app in `passwordDir`, named after the app, holding
# only the password (an agenix secret). An app without a file gets a role it
# cannot log in with yet.
#
# Network: scram-sha-256 from `allowedCIDRs` only, and the port is open only
# on `firewallInterfaces`. Tailscale (WireGuard) encrypts the path; there is no
# server TLS yet.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork.centralDb;

  ident = lib.types.strMatching "[a-z][a-z0-9_]*";

  psql = "${config.services.postgresql.package}/bin/psql";

  appNames = builtins.attrNames cfg.apps;
  admin = "${cfg.database}_admin";

  setupSql = pkgs.writeText "central-db-setup.sql" (
    ''
      \set ON_ERROR_STOP on
      SELECT 'CREATE ROLE ${admin} NOLOGIN'
        WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${admin}') \gexec
      SELECT 'CREATE DATABASE ${cfg.database} OWNER ${admin} TEMPLATE template0 ENCODING UTF8'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${cfg.database}') \gexec
      REVOKE ALL ON DATABASE ${cfg.database} FROM PUBLIC;
    ''
    + lib.concatMapStrings (app: ''
      SELECT 'CREATE ROLE ${app} LOGIN'
        WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${app}') \gexec
      GRANT CONNECT ON DATABASE ${cfg.database} TO ${app};
      ALTER ROLE ${app} SET search_path = ${app};
    '') appNames
    + lib.concatMapStrings (schema: ''
      SELECT 'CREATE ROLE ${schema}_read NOLOGIN'
        WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${schema}_read') \gexec
      SELECT 'CREATE ROLE ${schema}_write NOLOGIN'
        WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${schema}_write') \gexec
    '') (builtins.attrNames cfg.sharedSchemas)
    + ''
      \connect ${cfg.database}
      \set ON_ERROR_STOP on
      ALTER SCHEMA public OWNER TO ${admin};
      REVOKE ALL ON SCHEMA public FROM PUBLIC;
    ''
    + lib.concatMapStrings (app: ''
      CREATE SCHEMA IF NOT EXISTS ${app} AUTHORIZATION ${app};
      REVOKE ALL ON SCHEMA ${app} FROM PUBLIC;
    '') appNames
    + lib.concatStrings (
      lib.mapAttrsToList (schema: s: ''
        CREATE SCHEMA IF NOT EXISTS ${schema} AUTHORIZATION ${s.owner};
        ALTER SCHEMA ${schema} OWNER TO ${s.owner};
        REVOKE ALL ON SCHEMA ${schema} FROM PUBLIC;
        GRANT USAGE ON SCHEMA ${schema} TO ${schema}_read, ${schema}_write;
        GRANT SELECT ON ALL TABLES IN SCHEMA ${schema} TO ${schema}_read;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ${schema} TO ${schema}_write;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ${schema} TO ${schema}_write;
        ALTER DEFAULT PRIVILEGES FOR ROLE ${s.owner} IN SCHEMA ${schema}
          GRANT SELECT ON TABLES TO ${schema}_read;
        ALTER DEFAULT PRIVILEGES FOR ROLE ${s.owner} IN SCHEMA ${schema}
          GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${schema}_write;
        ALTER DEFAULT PRIVILEGES FOR ROLE ${s.owner} IN SCHEMA ${schema}
          GRANT USAGE, SELECT ON SEQUENCES TO ${schema}_write;
      '') cfg.sharedSchemas
    )
    + lib.concatStrings (
      lib.mapAttrsToList (
        app: a:
        lib.concatMapStrings (s: "GRANT ${s}_read TO ${app};\n") a.read
        + lib.concatMapStrings (s: "GRANT ${s}_write TO ${app};\n") a.write
      ) cfg.apps
    )
  );

  setPasswords = lib.concatMapStrings (app: ''
    if [ -r ${cfg.passwordDir}/${app} ]; then
      printf "ALTER ROLE ${app} PASSWORD :'pw';\n" \
        | ${psql} -v ON_ERROR_STOP=1 -v pw="$(cat ${cfg.passwordDir}/${app})" -q
    else
      echo "central-db: no password file for ${app}; it cannot log in yet" >&2
    fi
  '') appNames;
in
{
  options.patchwork.centralDb = {
    enable = lib.mkEnableOption "a central Patchwork PostgreSQL cluster";

    database = lib.mkOption {
      type = ident;
      example = "patchwork_central";
      description = "Name of the one database in this cluster.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
      description = "TCP port. Give clusters that share a host different ports.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_18;
      description = "PostgreSQL package. Change the major version only with a migration plan.";
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            read = lib.mkOption {
              type = lib.types.listOf ident;
              default = [ ];
              description = "Shared schemas this app may read.";
            };
            write = lib.mkOption {
              type = lib.types.listOf ident;
              default = [ ];
              description = "Shared schemas this app may read and write rows in.";
            };
          };
        }
      );
      default = { };
      example = {
        weave = { };
        selvage.read = [ "people" ];
      };
      description = "Apps. Each gets a LOGIN role and its own schema, both named after the app.";
    };

    sharedSchemas = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.owner = lib.mkOption {
            type = ident;
            description = "The app that owns this schema and runs its migrations.";
          };
        }
      );
      default = { };
      example = {
        people.owner = "weave";
      };
      description = "Schemas that several apps use.";
    };

    passwordDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/agenix/${cfg.database}";
      description = "Directory with one password file per app, named after the app.";
    };

    allowedCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "100.64.0.0/10" ];
      description = "Client networks pg_hba accepts. The default is the tailnet.";
    };

    firewallInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "tailscale0" ];
      description = "Interfaces the port is open on.";
    };

    backup.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Nightly compressed pg_dump to /var/backup/postgresql. This is a local
        copy only; it does not leave the host.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.mapAttrsToList (schema: s: {
        assertion = cfg.apps ? ${s.owner};
        message = "patchwork.centralDb.sharedSchemas.${schema}.owner (${s.owner}) is not in apps.";
      }) cfg.sharedSchemas
      ++ lib.concatLists (
        lib.mapAttrsToList (
          app: a:
          map (s: {
            assertion = cfg.sharedSchemas ? ${s};
            message = "patchwork.centralDb.apps.${app} grants ${s}, which is not in sharedSchemas.";
          }) (a.read ++ a.write)
        ) cfg.apps
      )
      ++ map (app: {
        assertion = !(cfg.sharedSchemas ? ${app});
        message = "patchwork.centralDb: ${app} is both an app and a shared schema.";
      }) appNames;

    services.postgresql = {
      enable = true;
      inherit (cfg) package;
      enableTCPIP = true;
      settings = {
        inherit (cfg) port;
        password_encryption = "scram-sha-256";
        shared_preload_libraries = "pg_stat_statements";
        track_io_timing = true;
        log_connections = true;
      };
      authentication = lib.mkForce (
        ''
          # TYPE  DATABASE  USER      ADDRESS  METHOD
          local   all       postgres           peer
        ''
        + lib.concatMapStrings (
          cidr: "host    ${cfg.database}  all  ${cidr}  scram-sha-256\n"
        ) cfg.allowedCIDRs
      );
    };

    networking.firewall.interfaces = lib.genAttrs cfg.firewallInterfaces (_: {
      allowedTCPPorts = [ cfg.port ];
    });

    # Idempotent: every statement checks first, so it runs on every boot and
    # every switch, and converges roles, schemas and grants on the declaration.
    # It only adds. Removing an app here does not drop its role or schema.
    systemd.services.central-db-setup = {
      description = "Roles, schemas and grants for ${cfg.database}";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ setupSql ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      environment.PGPORT = toString cfg.port;
      script = ''
        ${psql} -v ON_ERROR_STOP=1 -q -f ${setupSql}
        ${setPasswords}
      '';
    };

    services.postgresqlBackup = lib.mkIf cfg.backup.enable {
      enable = true;
      databases = [ cfg.database ];
      compression = "zstd";
      startAt = "*-*-* 02:15:00";
    };
    # pg_dump connects over the socket on the default port unless told.
    systemd.services."postgresqlBackup-${cfg.database}".environment = lib.mkIf cfg.backup.enable {
      PGPORT = toString cfg.port;
    };
  };
}
