# Evaluates nixosModules.quilt-alastor on a minimal host and checks the
# production and staging units and the Traefik routes. No VM: the containers
# need ghcr, seam and hem.
#   nix build .#checks.<system>.quilt-alastor
{
  pkgs,
  nixosSystem,
  module,
  agenixModule,
}:
let
  inherit (pkgs) lib;
  # The .age files are not in the repo until someone creates them.
  dummy = pkgs.writeText "dummy.age" "";
  host =
    (nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        agenixModule
        module
        {
          virtualisation.docker.enable = true;
          age.secrets.quilt-env.file = lib.mkForce dummy;
          age.secrets.quilt-ghcr-token.file = lib.mkForce dummy;
          age.secrets.quilt-staging-env.file = lib.mkForce dummy;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ];
    }).config;
  units = host.systemd.units;
  toml = host.environment.etc."traefik/conf.d/quilt.toml".source;
  web = units."quilt-web.service".text;
  worker = units."quilt-worker.service".text;
  stagingWeb = units."quilt-staging-web.service".text;
  stagingWorker = units."quilt-staging-worker.service".text;
  svc = host.systemd.services;
  afterLines =
    text: lib.concatStrings (lib.filter (l: lib.hasPrefix "After=" l) (lib.splitString "\n" text));
  checks = {
    "web unit exists" = units ? "quilt-web.service";
    "worker unit exists" = units ? "quilt-worker.service";
    "worker is partOf web" = lib.hasInfix "PartOf=quilt-web.service" worker;
    "worker starts after web" = lib.hasInfix "quilt-web.service" (afterLines worker);
    "web restarts on failure" = lib.hasInfix "Restart=on-failure" web;
    "staging web unit exists" = units ? "quilt-staging-web.service";
    "staging worker unit exists" = units ? "quilt-staging-worker.service";
    "staging worker is partOf staging web" =
      lib.hasInfix "PartOf=quilt-staging-web.service" stagingWorker;
    "staging worker starts after staging web" = lib.hasInfix "quilt-staging-web.service" (
      afterLines stagingWorker
    );
    "staging worker is not partOf production" =
      !(lib.hasInfix "PartOf=quilt-web.service" stagingWorker);
    "staging web restarts on failure" = lib.hasInfix "Restart=on-failure" stagingWeb;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "quilt-alastor: ${lib.concatStringsSep ", " failed}";
# The Traefik fragment and the start script are build outputs, so check them
# at build time.
pkgs.runCommand "quilt-alastor" { } ''
  # `! grep` does not stop a `set -e` script, so check absence like this.
  absent() {
    if grep -F -- "$1" "$2"; then
      echo "unexpected '$1' in $2" >&2
      exit 1
    fi
  }

  grep -F 'Host(`quilt.patchworklabs.org`)' ${toml}
  grep -F 'http://127.0.0.1:3005' ${toml}
  grep -F 'websecure' ${toml}
  grep -F 'cloudflare' ${toml}
  grep -F 'hsts' ${toml}
  grep -F -- '-b 127.0.0.1 -p 3005' ${host.systemd.services.quilt-web.serviceConfig.ExecStart}
  grep -F 'good_job start' ${host.systemd.services.quilt-worker.serviceConfig.ExecStart}

  # Production: RAILS_ENV=production, the production env file, no sandbox.
  grep -F 'RAILS_ENV=production' ${svc.quilt-web.serviceConfig.ExecStart}
  grep -F 'RAILS_ENV=production' ${svc.quilt-worker.serviceConfig.ExecStart}
  grep -F '/run/agenix/quilt-env ' ${svc.quilt-web.serviceConfig.ExecStart}
  absent 'api-sandbox' ${svc.quilt-web.serviceConfig.ExecStart}
  absent 'api-sandbox' ${svc.quilt-worker.serviceConfig.ExecStart}

  # Staging: own route, port, env file, RAILS_ENV=staging and the sandbox.
  grep -F 'Host(`quilt-staging.patchworklabs.org`)' ${toml}
  grep -F 'http://127.0.0.1:3006' ${toml}
  grep -F -- '--name quilt-staging-web' ${svc.quilt-staging-web.serviceConfig.ExecStart}
  grep -F -- '-b 127.0.0.1 -p 3006' ${svc.quilt-staging-web.serviceConfig.ExecStart}
  grep -F -- '--name quilt-staging-worker' ${svc.quilt-staging-worker.serviceConfig.ExecStart}
  grep -F 'good_job start' ${svc.quilt-staging-worker.serviceConfig.ExecStart}
  grep -F 'http://127.0.0.1:3006/up' ${lib.last svc.quilt-staging-worker.serviceConfig.ExecStartPre}
  for f in ${svc.quilt-staging-web.serviceConfig.ExecStart} ${svc.quilt-staging-worker.serviceConfig.ExecStart}; do
    grep -F 'RAILS_ENV=staging' $f
    absent 'RAILS_ENV=production' $f
    grep -F '/run/agenix/quilt-staging-env ' $f
    grep -F "MERCURY_API_BASE=https://api-sandbox.mercury.com/api/v1/" $f
    grep -F "WEAVE_ISSUER=https://weave-staging.patchworklabs.org" $f
  done
  touch $out
''
