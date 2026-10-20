# Checks modules/banner on the real lab hosts and on a host that does not
# turn it on. The banner is off by default, because alastor must not get it.
#   nix build .#checks.<system>.banner
{
  pkgs,
  nixosSystem,
  hosts,
}:
let
  inherit (pkgs) lib;
  seam = hosts.seam.config;

  # A host with the module and no patchwork.banner settings.
  plain =
    (nixosSystem {
      system = "x86_64-linux";
      modules = [
        ../modules/banner
        {
          networking.hostName = "plain";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "ext4";
          };
          system.stateVersion = "26.05";
        }
      ];
    }).config;

  checks = {
    "seam motd has the spaced name" = lib.hasInfix "S E A M" seam.users.motd;
    "seam motd has its role" = lib.hasInfix "patchwork . restricted central db" seam.users.motd;
    "seam sets the SSH banner" = seam.services.openssh.settings.Banner != null;
    "every lab host has a motd" = lib.all (h: hosts.${h}.config.users.motd != null) (
      builtins.attrNames hosts
    );
    "banner is off by default" = !plain.patchwork.banner.enable;
    "default has no motd" = plain.users.motd == null || plain.users.motd == "";
    "default has no SSH banner" = plain.services.openssh.settings.Banner == null;
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "banner: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "banner" { } ''
  grep -F 'S E A M' ${pkgs.writeText "motd" seam.users.motd}
  grep -F 'seam . patchwork restricted central db' ${seam.services.openssh.settings.Banner}
  touch $out
''
