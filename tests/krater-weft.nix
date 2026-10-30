# Evaluates weft (hosts/weft) as it is: Krater staging on (its Weave client id
# and env file exist), Krater production off (hosts/weft/krater-production.nix).
# Checks the units, the nginx routes and the alastor edge routes. Then turns
# staging off, and production on with a placeholder id, to check both
# switches, and checks the database schema for both values of the production
# switch. No VM: the containers need GitHub, hem and the Krater image.
#   nix build .#checks.<system>.krater-weft
{
  pkgs,
  nixosSystem,
  weft,
  skein,
  hem,
  edgeModule,
}:
let
  inherit (pkgs) lib;
  # weft as deployed: staging on, production off.
  on = weft.config;
  off =
    (weft.extendModules {
      modules = [ { patchwork.services.krater.enable = lib.mkForce false; } ];
    }).config;
  schemaFor = (import ../hosts/central-db-schema.nix).schemaFor;
  schemaOff = schemaFor false;
  schemaOn = schemaFor true;
  # As hem merges them (hosts/hem/configuration.nix).
  hemApps = schema: schema.central.apps // schema.central.stagingOnlyApps;
  switchFile = (import ../hosts/weft/krater-production.nix).enable;
  prod =
    (weft.extendModules {
      modules = [
        {
          patchwork.services.krater-production = {
            enable = lib.mkForce true;
            weave.clientId = lib.mkForce "test-prod-client-id";
          };
        }
      ];
    }).config;
  mkEdge =
    extra:
    (nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        edgeModule
        extra
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ];
    }).config;
  edge = mkEdge { };
  edgeProd = mkEdge { patchwork.edge.kraterProduction = true; };
  edgeProdToml = edgeProd.environment.etc."traefik/conf.d/patchwork.toml".source;
  units = on.systemd.units;
  pvc = prod.systemd.services;
  pvhosts = prod.services.nginx.virtualHosts;
  svc = on.systemd.services;
  vhosts = on.services.nginx.virtualHosts;
  edgeToml = edge.environment.etc."traefik/conf.d/patchwork.toml".source;
  checks = {
    "staging is on by default" = on.patchwork.services.krater.enable;
    "staging secret by default" = on.age.secrets ? krater-staging-env;
    "staging client id is set" = on.patchwork.services.krater.weave.clientId != "";
    "staging pins hem" =
      on.patchwork.services.krater.extraHosts."hem.wildebeest-stargazer.ts.net" == "100.67.124.123";
    "no krater unit while off" = !(off.systemd.units ? "krater-web.service");
    "no krater vhost while off" = !(off.services.nginx.virtualHosts ? krater);
    "catch-all vhost" =
      on.services.nginx.virtualHosts.catch-all.default
      && on.services.nginx.virtualHosts.catch-all.locations."/".return == "444";
    "catch-all stays while krater is off" = off.services.nginx.virtualHosts ? catch-all;
    "web unit exists" = units ? "krater-web.service";
    "worker unit exists" = units ? "krater-worker.service";
    "storage unit exists" = units ? "krater-storage.service";
    "build unit exists" = units ? "krater-build.service";
    "no traefik fragment on weft" = !(on.environment.etc ? "traefik/conf.d/krater.toml");
    "portal vhost" =
      vhosts.krater.serverName == "krater-staging.patchworklabs.org"
      && vhosts.krater.locations."/".proxyPass == "http://127.0.0.1:3010";
    "storage vhost" =
      vhosts.krater-storage.serverName == "krater-staging-storage.patchworklabs.org"
      && vhosts.krater-storage.locations."/".proxyPass == "http://127.0.0.1:3011";
    "storage has no body limit" =
      lib.hasInfix "client_max_body_size 0;"
        vhosts.krater-storage.locations."/".extraConfig;
    "nginx passes alastor's proto" =
      lib.hasInfix "X-Forwarded-Proto $http_x_forwarded_proto" on.services.nginx.commonHttpConfig;
    "port 80 only on the tailnet" =
      lib.elem 80 on.networking.firewall.interfaces.tailscale0.allowedTCPPorts
      && !(lib.elem 80 on.networking.firewall.allowedTCPPorts);
    "weave staging issuer" =
      on.patchwork.services.krater.weave.issuer == "https://weave-staging.patchworklabs.org";
    "trusted proxy count: Cloudflare, Traefik, nginx" =
      on.patchwork.services.krater.extraEnv.KRATER_TRUSTED_PROXY_COUNT == "3";
    "no real_ip rewrite on weft" = !(lib.hasInfix "real_ip_header" on.services.nginx.commonHttpConfig);
    "nginx appends to X-Forwarded-For" =
      lib.hasInfix "X-Forwarded-For $proxy_add_x_forwarded_for" on.services.nginx.commonHttpConfig;
    "no events to Quilt" = on.patchwork.services.krater.extraEnv.KRATER_QUILT_URL == "";
    "staging shows the staging marker" = on.patchwork.services.krater.extraEnv.KRATER_STAGING == "true";
    "production has no staging marker" =
      !(prod.patchwork.services.krater-production.extraEnv ? KRATER_STAGING);
    "staging label prefix" = on.patchwork.services.krater.compute.labelPrefix == "krater-staging-";
    "storage volume limit" =
      on.patchwork.services.krater.storage.maxVolumes == 8
      && prod.patchwork.services.krater-production.storage.maxVolumes == 8;
    "krater is not on skein" = !(skein.config.patchwork.centralDb.apps ? krater);
    "production is off by default" = !on.patchwork.services.krater-production.enable;
    "no production unit by default" = !(units ? "krater-prod-web.service");
    "no production vhost by default" = !(vhosts ? krater-prod);
    "no production secret by default" = !(on.age.secrets ? krater-env);
    "edge default follows the switch file" = edge.patchwork.edge.kraterProduction == switchFile;
    "switch off: krater only on hem" =
      !(schemaOff.central.apps ? krater)
      && schemaOff.central.stagingOnlyApps ? krater
      && hemApps schemaOff ? krater;
    "switch on: krater on skein and on hem" =
      schemaOn.central.apps ? krater
      && schemaOn.central.stagingOnlyApps == { }
      && hemApps schemaOn ? krater;
    # skein maps each app in `apps` to secrets/central-prod-<app>.age
    # (hosts/skein/configuration.nix), so with the switch on it loads this file.
    "skein's krater password file exists" = builtins.pathExists ../secrets/central-prod-krater.age;
    "the file is the schema for the switch" =
      (import ../hosts/central-db-schema.nix).central == (schemaFor switchFile).central;
    "production units when on" =
      prod.systemd.units ? "krater-prod-web.service"
      && prod.systemd.units ? "krater-prod-worker.service"
      && prod.systemd.units ? "krater-prod-storage.service"
      && prod.systemd.units ? "krater-prod-build.service"
      && prod.systemd.units ? "krater-prod-network.service";
    "production vhosts when on" =
      pvhosts.krater-prod.serverName == "krater.patchworklabs.org"
      && pvhosts.krater-prod.locations."/".proxyPass == "http://127.0.0.1:3012"
      && pvhosts.krater-prod-storage.serverName == "krater-storage.patchworklabs.org"
      && pvhosts.krater-prod-storage.locations."/".proxyPass == "http://127.0.0.1:3013";
    "production uses weave production" =
      prod.patchwork.services.krater-production.weave.issuer == "https://weave.patchworklabs.org";
    "production label prefix" =
      prod.patchwork.services.krater-production.compute.labelPrefix == "krater-prod-";
    "staging keeps weave staging" =
      prod.patchwork.services.krater.weave.issuer == "https://weave-staging.patchworklabs.org";
    "CI deploy user for staging" =
      on.users.users ? krater-deploy && on.users.users.krater-deploy.openssh.authorizedKeys.keys != [ ];
    "CI deploy user may only build and restart staging" =
      let
        rules = lib.filter (r: r.users == [ "krater-deploy" ]) on.security.sudo.extraRules;
        cmds = lib.concatMap (r: map (c: c.command) r.commands) rules;
      in
      lib.sort lib.lessThan cmds == [
        "/run/current-system/sw/bin/systemctl restart krater-web"
        "/run/current-system/sw/bin/systemctl start krater-build"
      ];
    "CI deploy user writes source-rev" =
      lib.elem "f /var/lib/krater/source-rev 0644 krater-deploy users -" on.systemd.tmpfiles.rules;
    "sshd on 2222 on the tailnet for CI" =
      lib.elem 2222 on.services.openssh.ports
      && lib.elem 2222 on.networking.firewall.interfaces.tailscale0.allowedTCPPorts;
    "no CI deploy user for production" =
      !(on.users.users ? krater-prod-deploy) && !(prod.users.users ? krater-prod-deploy);
    "krater is on hem" = hem.config.containers.central-staging.config.patchwork.centralDb.apps ? krater;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "krater-weft: ${lib.concatStringsSep ", " failed}";
# The start scripts are build outputs, so check them at build time.
pkgs.runCommand "krater-weft" { } ''
  set -eu
  absent() {
    if grep -F -- "$1" "$2"; then
      echo "unexpected '$1' in $2" >&2
      exit 1
    fi
  }
  # lib.escapeShellArg leaves a name:address with no special characters
  # unquoted.
  hem="--add-host hem.wildebeest-stargazer.ts.net:100.67.124.123"

  # The portal, the worker, the database wait and the migrations get hem's
  # tailnet address. SeaweedFS does not talk to the database.
  grep -F -- "$hem" ${svc.krater-web.serviceConfig.ExecStart}
  grep -F -- "$hem" ${svc.krater-worker.serviceConfig.ExecStart}
  for f in ${lib.concatStringsSep " " (lib.filter (lib.hasPrefix "/nix/store/") (lib.toList svc.krater-web.serviceConfig.ExecStartPre))}; do
    if grep -qF 'alembic upgrade head' "$f"; then
      test "$(grep -cF -- "$hem" "$f")" = 3
      # The settings check runs before the database wait.
      grep -F 'from krater.config import get_settings; get_settings()' "$f"
      prepare=1
    fi
  done
  test "''${prepare:-0}" = 1
  absent "--add-host" ${svc.krater-storage.serviceConfig.ExecStart}

  grep -F -- '--env VOLUME_MAX=8' ${svc.krater-storage.serviceConfig.ExecStart}
  grep -F -- '--env VOLUME_MAX=8' ${pvc.krater-prod-storage.serviceConfig.ExecStart}
  grep -F 'docker builder prune -f --filter until=168h' ${svc.krater-build.serviceConfig.ExecStart}

  # Loopback only: nginx is the way in.
  grep -F -- '--publish 127.0.0.1:3010:8000' ${svc.krater-web.serviceConfig.ExecStart}
  grep -F -- '--publish 127.0.0.1:3011:8333' ${svc.krater-storage.serviceConfig.ExecStart}

  # alastor routes both names to weft over the tailnet.
  grep -F 'Host(`krater-staging.patchworklabs.org`)' ${edgeToml}
  grep -F 'Host(`krater-staging-storage.patchworklabs.org`)' ${edgeToml}
  absent 'Host(`krater.patchworklabs.org`)' ${edgeToml}
  absent 'Host(`krater-storage.patchworklabs.org`)' ${edgeToml}

  # Production: its own network, image repository, state and ports, and skein.
  skein="--add-host skein.wildebeest-stargazer.ts.net:100.109.223.51"
  grep -F -- "$skein" ${pvc.krater-prod-web.serviceConfig.ExecStart}
  absent "hem.wildebeest-stargazer.ts.net" ${pvc.krater-prod-web.serviceConfig.ExecStart}
  grep -F -- '--network krater-prod ' ${pvc.krater-prod-web.serviceConfig.ExecStart}
  grep -F -- '--publish 127.0.0.1:3012:8000' ${pvc.krater-prod-web.serviceConfig.ExecStart}
  grep -F -- '--publish 127.0.0.1:3013:8333' ${pvc.krater-prod-storage.serviceConfig.ExecStart}
  grep -F -- '/var/lib/krater-prod/storage:/data' ${pvc.krater-prod-storage.serviceConfig.ExecStart}
  grep -F 'docker image ls krater-prod ' ${pvc.krater-prod-build.serviceConfig.ExecStart}
  # With the switch on, alastor routes production's two names to weft too.
  grep -F 'Host(`krater.patchworklabs.org`)' ${edgeProdToml}
  grep -F 'Host(`krater-storage.patchworklabs.org`)' ${edgeProdToml}
  grep -F 'Host(`krater-staging.patchworklabs.org`)' ${edgeProdToml}

  # Staging's build cleans only its own repository, so it never removes a
  # production image.
  grep -F 'docker image ls krater ' ${svc.krater-build.serviceConfig.ExecStart}
  grep -F 'http://weft.wildebeest-stargazer.ts.net' ${edgeToml}
  touch $out
''
