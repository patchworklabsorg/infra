# hem — both staging clusters (pve01 VMID 358, 10.100.90.58, 2 GB; VMID and
# address to be confirmed free before create)
#
# patchwork_central on 5432 and patchwork_central_restricted on 5433, each in
# its own NixOS container, so they are two clusters with separate data
# directories, superusers and pg_hba, like prod. The containers share the
# host's network, so the ports must differ.
#
# Passwords: the same model as skein and seam. For each app in the schema
# with a secrets/<env>-staging-<app>.age file, the host decrypts it to
# /run/central-db-passwords/<database>/<app>, and that directory is bound
# into the cluster's container, where central-db-setup reads it. An app
# without a file gets a role that cannot log in yet. hem's host key must be a
# recipient of each file (secrets/secrets.nix).
#
# Why not /run/agenix/<database> as on seam: /run/agenix is a symlink to the
# current agenix generation, and agenix makes a new generation on each
# activation. A bind mount resolves its host path once, when the container
# starts, so the container would keep an old generation. The files are real
# files (symlink = false), because a symlink into /run/agenix.d does not
# resolve inside the container.
#
# Connection strings (Tailscale encrypts the path, so sslmode=disable):
#   postgres://<app>:<pw>@hem.wildebeest-stargazer.ts.net:5432/patchwork_central?sslmode=disable
#   postgres://<app>:<pw>@hem.wildebeest-stargazer.ts.net:5433/patchwork_central_restricted?sslmode=disable
{ config, lib, ... }:
let
  schemas = import ../central-db-schema.nix;

  passwordRoot = "/run/central-db-passwords";

  # secrets/<prefix>-<app>.age for each app in the schema that has one.
  passwordFilesFor =
    prefix: schema:
    lib.filterAttrs (_: builtins.pathExists) (
      lib.mapAttrs (app: _: ../../secrets/${prefix}-${app}.age) schema.apps
    );

  clusters = {
    central-staging = {
      database = "patchwork_central";
      port = 5432;
      # Same reach as prod: central from the LAN and the tailnet.
      allowedCIDRs = [
        "10.100.90.0/24"
        "100.64.0.0/10"
      ];
      schema = schemas.central;
      passwordFiles = passwordFilesFor "central-staging" schemas.central;
      secretPrefix = "central-staging";
    };
    restricted-staging = {
      database = "patchwork_central_restricted";
      port = 5433;
      # Restricted from the tailnet only, as on seam.
      allowedCIDRs = [ "100.64.0.0/10" ];
      schema = schemas.restricted;
      passwordFiles = passwordFilesFor "restricted-staging" schemas.restricted;
      secretPrefix = "restricted-staging";
    };
  };

  container = c: {
    autoStart = true;
    # Host network: the container's Postgres listens on the host's interfaces.
    privateNetwork = false;
    bindMounts.${passwordRoot} = {
      hostPath = "${passwordRoot}/${c.database}";
      isReadOnly = true;
    };
    config =
      { ... }:
      {
        imports = [ ../../modules/central-db ];
        patchwork.centralDb = {
          enable = true;
          inherit (c) database port allowedCIDRs;
          inherit (c.schema) apps sharedSchemas;
          passwordDir = passwordRoot;
          # The host firewall below opens the ports. The container has none.
          firewallInterfaces = [ ];
        };
        # Set the password again when its secret changes. The changed
        # container config reaches the container on the host's next switch.
        systemd.services.central-db-setup.restartTriggers = builtins.attrValues c.passwordFiles;
        networking.firewall.enable = false;
        system.stateVersion = "26.05";
      };
  };

  # One agenix secret per password file, as a real file owned by postgres.
  secretsFor =
    c:
    lib.mapAttrs' (
      app: file:
      lib.nameValuePair "${c.secretPrefix}-${app}" {
        inherit file;
        path = "${passwordRoot}/${c.database}/${app}";
        symlink = false;
        owner = "postgres";
        group = "postgres";
        mode = "400";
      }
    ) c.passwordFiles;
in
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
  ];

  networking.hostName = "hem";
  patchwork.lanAddress = "10.100.90.58";
  patchwork.banner.role = "staging db";

  containers = lib.mapAttrs (_: container) clusters;

  age.secrets = lib.mkMerge (map secretsFor (builtins.attrValues clusters));

  # The containers share the host's user IDs. A host postgres user with the
  # NixOS postgres uid and gid makes the secrets readable by the containers'
  # postgres.
  users.users.postgres = {
    uid = config.ids.uids.postgres;
    group = "postgres";
    isSystemUser = true;
  };
  users.groups.postgres.gid = config.ids.gids.postgres;

  # The bind mounts need the directories even before any password exists.
  systemd.tmpfiles.rules = [
    "d ${passwordRoot} 0755 root root -"
  ]
  ++ map (c: "d ${passwordRoot}/${c.database} 0755 root root -") (builtins.attrValues clusters);

  networking.firewall.interfaces = {
    ens18.allowedTCPPorts = [ 5432 ];
    tailscale0.allowedTCPPorts = [
      5432
      5433
    ];
  };

  system.stateVersion = "26.05";
}
