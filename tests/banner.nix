# Checks modules/banner on the real lab hosts and on a host with no banner
# settings. The banner is on by default. alastor must not get it, so no module
# in nixosModules may bring in the patchwork.banner option, not even through
# an import.
#   nix build .#checks.<system>.banner
{
  pkgs,
  nixosSystem,
  hosts,
  nixosModules,
  agenixModule,
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

  # True if the module, with its imports, declares patchwork.banner. Only the
  # options are read, so the module needs no secrets or host settings.
  bringsBanner =
    m:
    let
      inherit
        (nixosSystem {
          system = "x86_64-linux";
          modules = [
            agenixModule
            m
          ];
        })
        options
        ;
    in
    options ? patchwork && options.patchwork ? banner;

  checks = {
    "seam motd has the spaced name" = lib.hasInfix "S E A M" seam.users.motd;
    "seam motd has its role" = lib.hasInfix "patchwork . restricted central db" seam.users.motd;
    "seam sets the SSH banner" = seam.services.openssh.settings.Banner != null;
    "every lab host has a motd" = lib.all (h: hosts.${h}.config.users.motd != null) (
      builtins.attrNames hosts
    );
    "banner is on by default" = plain.patchwork.banner.enable;
    "default motd has the spaced name" = lib.hasInfix "P L A I N" plain.users.motd;
    "default motd has no role" = lib.hasInfix "    patchwork\n" plain.users.motd;
    "default sets the SSH banner" = plain.services.openssh.settings.Banner != null;
    "no exported module brings in the banner, so alastor does not get it" =
      !(lib.any bringsBanner (builtins.attrValues nixosModules));
  };
  failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
in
assert lib.assertMsg (failed == [ ]) "banner: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "banner" { } ''
  grep -F 'S E A M' ${pkgs.writeText "motd" seam.users.motd}
  grep -F 'seam . patchwork restricted central db' ${seam.services.openssh.settings.Banner}
  touch $out
''
