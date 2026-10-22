# Evaluates weft (hosts/weft) with Krater turned on and checks the units, the
# nginx routes and the alastor edge routes. Krater stays off on the real weft
# until its Weave client id is set, so this test sets a placeholder id. No VM:
# the containers need GitHub, skein and the Krater image.
#   nix build .#checks.<system>.krater-weft
{
  pkgs,
  nixosSystem,
  weft,
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
    "krater-env is weft's secret" = off.age.secrets ? krater-env;
    "web unit exists" = units ? "krater-web.service";
    "worker unit exists" = units ? "krater-worker.service";
    "storage unit exists" = units ? "krater-storage.service";
    "build unit exists" = units ? "krater-build.service";
    "no traefik fragment on weft" = !(on.environment.etc ? "traefik/conf.d/krater.toml");
    "portal vhost" =
      vhosts.krater.serverName == "krater.patchworklabs.org"
      && vhosts.krater.locations."/".proxyPass == "http://127.0.0.1:3010";
    "storage vhost" =
      vhosts.krater-storage.serverName == "krater-storage.patchworklabs.org"
      && vhosts.krater-storage.locations."/".proxyPass == "http://127.0.0.1:3011";
    "storage has no body limit" =
      lib.hasInfix "client_max_body_size 0;"
        vhosts.krater-storage.locations."/".extraConfig;
    "nginx passes alastor's proto" =
      lib.hasInfix "X-Forwarded-Proto $http_x_forwarded_proto" on.services.nginx.commonHttpConfig;
    "port 80 only on the tailnet" =
      lib.elem 80 on.networking.firewall.interfaces.tailscale0.allowedTCPPorts
      && !(lib.elem 80 on.networking.firewall.allowedTCPPorts);
    "trusted proxy count" = on.patchwork.services.krater.extraEnv.KRATER_TRUSTED_PROXY_COUNT == "2";
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
  skein="--add-host 'skein.wildebeest-stargazer.ts.net:100.109.223.51'"

  # The portal, the worker, the database wait and the migrations get skein's
  # tailnet address. SeaweedFS does not talk to the database.
  grep -F -- "$skein" ${svc.krater-web.serviceConfig.ExecStart}
  grep -F -- "$skein" ${svc.krater-worker.serviceConfig.ExecStart}
  for f in ${lib.concatStringsSep " " (lib.toList svc.krater-web.serviceConfig.ExecStartPre)}; do
    if grep -qF 'alembic upgrade head' "$f"; then
      test "$(grep -cF -- "$skein" "$f")" = 2
      prepare=1
    fi
  done
  test "''${prepare:-0}" = 1
  absent "--add-host" ${svc.krater-storage.serviceConfig.ExecStart}

  # Loopback only: nginx is the way in.
  grep -F -- '--publish 127.0.0.1:3010:8000' ${svc.krater-web.serviceConfig.ExecStart}
  grep -F -- '--publish 127.0.0.1:3011:8333' ${svc.krater-storage.serviceConfig.ExecStart}

  # alastor routes both names to weft over the tailnet.
  grep -F 'Host(`krater.patchworklabs.org`)' ${edgeToml}
  grep -F 'Host(`krater-storage.patchworklabs.org`)' ${edgeToml}
  grep -F 'http://weft.wildebeest-stargazer.ts.net' ${edgeToml}
  touch $out
''
