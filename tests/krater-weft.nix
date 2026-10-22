# Evaluates weft (hosts/weft) with Krater staging turned on and checks the
# units, the nginx routes and the alastor edge routes. Krater stays off on the
# real weft until its env file and its Weave client id exist, so this test
# turns it on with a placeholder id. No VM: the containers need GitHub, hem
# and the Krater image.
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
  off = weft.config;
  on =
    (weft.extendModules {
      modules = [
        {
          patchwork.services.krater = {
            enable = lib.mkForce true;
            weave.clientId = lib.mkForce "test-client-id";
          };
        }
      ];
    }).config;
  edge =
    (nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        edgeModule
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
  units = on.systemd.units;
  svc = on.systemd.services;
  vhosts = on.services.nginx.virtualHosts;
  edgeToml = edge.environment.etc."traefik/conf.d/patchwork.toml".source;
  checks = {
    "krater is off on weft without a client id" = !off.patchwork.services.krater.enable;
    "no krater unit while off" = !(off.systemd.units ? "krater-web.service");
    "no krater vhost while off" = !(off.services.nginx.virtualHosts ? krater);
    "no krater secret until the env file exists" = !(off.age.secrets ? krater-staging-env);
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
    "staging label prefix" = on.patchwork.services.krater.compute.labelPrefix == "krater-staging-";
    "storage volume limit" = on.patchwork.services.krater.storage.maxVolumes == 12;
    "krater is not on skein" = !(skein.config.patchwork.centralDb.apps ? krater);
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

  grep -F -- '--env VOLUME_MAX=12' ${svc.krater-storage.serviceConfig.ExecStart}
  grep -F 'docker builder prune -f --filter until=168h' ${svc.krater-build.serviceConfig.ExecStart}

  # Loopback only: nginx is the way in.
  grep -F -- '--publish 127.0.0.1:3010:8000' ${svc.krater-web.serviceConfig.ExecStart}
  grep -F -- '--publish 127.0.0.1:3011:8333' ${svc.krater-storage.serviceConfig.ExecStart}

  # alastor routes both names to weft over the tailnet.
  grep -F 'Host(`krater-staging.patchworklabs.org`)' ${edgeToml}
  grep -F 'Host(`krater-staging-storage.patchworklabs.org`)' ${edgeToml}
  absent 'Host(`krater.patchworklabs.org`)' ${edgeToml}
  grep -F 'http://weft.wildebeest-stargazer.ts.net' ${edgeToml}
  touch $out
''
