# Sewing-theme login banners, in the style of thimble's: a small box before
# the SSH login (services.openssh.settings.Banner) and a needle and patch
# after it (users.motd). On by default: flake.nix adds this module only to the
# Patchwork lab hosts. It is not in nixosModules and modules/common does not
# import it, so alastor never gets it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork.banner;
  host = config.networking.hostName;

  # thimble -> "T H I M B L E"
  spacedName = lib.concatStringsSep " " (lib.stringToCharacters (lib.toUpper host));

  lines = ls: lib.concatStringsSep "\n" ls + "\n";

  # "central db" -> " central db", so a host without a role has no stray text.
  role = lib.optionalString (cfg.role != null) " ${cfg.role}";

  preLogin =
    lines [
      "   .-------."
      "   |=======|"
      "   |  | |  |"
      "   `-------`"
      "   ${host} . patchwork${role}"
    ]
    + "\n";

  postLogin =
    lines (
      cfg.art
      ++ [
        "    ${spacedName}"
        "    patchwork${lib.optionalString (cfg.role != null) " . ${cfg.role}"}"
      ]
    )
    + "\n";
in
{
  options.patchwork.banner = {
    enable = lib.mkEnableOption "the sewing-theme login banners" // {
      default = true;
    };

    role = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "central db";
      description = "What the host does. Short and lower case. It goes in both banners.";
    };

    art = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "        \\"
        "         \\  o o o"
        "     .----\\------."
        "     | +  o\\ |   |"
        "     |-----+\\----|"
        "     |   | | \\ L |"
        "     `--.  | |\\--`"
        "         `-`  \\"
        "               \\"
      ];
      description = "The art lines of the banner shown after login. A needle and a patch.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.motd = postLogin;
    services.openssh.settings.Banner = toString (pkgs.writeText "ssh-banner" preLogin);
  };
}
