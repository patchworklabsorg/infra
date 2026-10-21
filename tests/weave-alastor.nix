# Evaluates nixosModules.weave-alastor on a minimal host and checks the AD
# settings of the staging instance: the DC host entries, the mounts and the
# AD env reach staging, and none of them reach production. No VM: the
# containers need ghcr and the DCs.
#   nix build .#checks.<system>.weave-alastor
{
  pkgs,
  nixosSystem,
  module,
  agenixModule,
}:
let
  inherit (pkgs) lib;
  # The .age files are encrypted to jsp and alastor only.
  dummy = pkgs.writeText "dummy.age" "";
  host =
    (nixosSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        agenixModule
        module
        {
          virtualisation.docker.enable = true;
          age.secrets.weave-env.file = lib.mkForce dummy;
          age.secrets.weave-staging-env.file = lib.mkForce dummy;
          age.secrets.weave-ldap.file = lib.mkForce dummy;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ];
    }).config;
  svc = host.systemd.services;
  ldap = host.age.secrets.weave-ldap;
  # The db:prepare script is the last ExecStartPre of each web unit.
  prepare = name: lib.last svc.${name}.serviceConfig.ExecStartPre;
  checks = {
    "ldap secret is a real file" = !ldap.symlink;
    "ldap secret is in its own directory" = ldap.path == "/run/weave-staging-ad/bind-password";
    "ldap secret is root-only" = ldap.mode == "400";
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "weave-alastor: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "weave-alastor" { } ''
  # `! grep` does not stop a `set -e` script, so check absence like this.
  absent() {
    if grep -F -- "$1" "$2"; then
      echo "unexpected '$1' in $2" >&2
      exit 1
    fi
  }

  # Staging: db:prepare, web and worker all get the AD settings.
  for f in ${prepare "weave-staging-web"} ${svc.weave-staging-web.serviceConfig.ExecStart} ${svc.weave-staging-worker.serviceConfig.ExecStart}; do
    grep -F -- "--add-host loom.patchwork.internal:100.75.125.1 " $f
    grep -F -- "--add-host spindle.patchwork.internal:100.108.7.59 " $f
    grep -F -- "--volume /run/weave-staging-ad:/run/weave/ad:ro " $f
    grep -F -- '-patchwork.internal-ca-chain.pem:/run/weave/ad-ca.pem:ro' $f
    grep -F -- "--env 'AD_ENABLED=true'" $f
    grep -F -- "--env 'AD_BIND_PASSWORD_FILE=/run/weave/ad/bind-password'" $f
    grep -F -- "--env 'AD_CA_FILE=/run/weave/ad-ca.pem'" $f
    grep -F -- "--env 'AD_BIND_DN=CN=svc-weave-ldap,OU=Service-Accounts,OU=Patchwork,DC=patchwork,DC=internal'" $f
  done

  # The chain in the store is the forest chain: issuing CA and root.
  chain=$(grep -o -- '/nix/store/[^:]*-patchwork.internal-ca-chain.pem' ${svc.weave-staging-web.serviceConfig.ExecStart} | head -1)
  grep -F 'CN=Patchwork-Issuing-CA' "$chain"
  grep -F 'CN=Patchwork-Root-CA' "$chain"
  test "$(grep -c 'BEGIN CERTIFICATE' "$chain")" -eq 2

  # Production: none of it.
  for f in ${prepare "weave-web"} ${svc.weave-web.serviceConfig.ExecStart} ${svc.weave-worker.serviceConfig.ExecStart}; do
    absent '--add-host' $f
    absent '/run/weave/' $f
    absent 'AD_' $f
  done
  touch $out
''
