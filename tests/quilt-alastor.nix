# Evaluates nixosModules.quilt-alastor on a minimal host and checks the units
# and the Traefik route. No VM: the containers need ghcr and seam.
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
  checks = {
    "web unit exists" = units ? "quilt-web.service";
    "worker unit exists" = units ? "quilt-worker.service";
    "worker is partOf web" = lib.hasInfix "PartOf=quilt-web.service" worker;
    "worker starts after web" = lib.hasInfix "quilt-web.service" (
      lib.concatStrings (lib.filter (l: lib.hasPrefix "After=" l) (lib.splitString "\n" worker))
    );
    "web restarts on failure" = lib.hasInfix "Restart=on-failure" web;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "quilt-alastor: ${lib.concatStringsSep ", " failed}";
# The Traefik fragment and the start script are build outputs, so check them
# at build time.
pkgs.runCommand "quilt-alastor" { } ''
  grep -F 'Host(`quilt.patchworklabs.org`)' ${toml}
  grep -F 'http://127.0.0.1:3005' ${toml}
  grep -F 'websecure' ${toml}
  grep -F 'cloudflare' ${toml}
  grep -F 'hsts' ${toml}
  grep -F -- '-b 127.0.0.1 -p 3005' ${host.systemd.services.quilt-web.serviceConfig.ExecStart}
  grep -F 'good_job start' ${host.systemd.services.quilt-worker.serviceConfig.ExecStart}
  touch $out
''
