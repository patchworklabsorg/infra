# Base for every Patchwork NixOS host: accounts, SSH, sudo, Nix, Tailscale,
# the Proxmox guest agent and the patchwork.internal join (modules/ad-join).
# Each host in hosts/ imports this.
#
# The local accounts below are the break-glass way in. Staff log in with their
# AD account (modules/ad-join).
#
# Login is by SSH key only (patchworklabsorg/core#9). With mutableUsers = false
# and no password set, no account can log in with a password, so sudo cannot
# ask for one and wheel members use it without.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork;

  keys = import ./keys.nix;
in
{
  imports = [ ../ad-join ];

  options.patchwork = {
    admins = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames keys));
      default = [
        "jsp"
        "krn"
        "yc"
      ];
      description = "Accounts in wheel. Every host gets these.";
    };

    members = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames keys));
      default = [ ];
      example = [ "dom" ];
      description = "Accounts without wheel. Only hosts where members run their own things set this.";
    };

    lanAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.100.90.55";
      description = ''
        Static address on ens18 (/24). Infra hosts sit in .1-.99, which the
        PW DHCP scope excludes, so they cannot use DHCP. null means DHCP.
      '';
    };

    lanGateway = lib.mkOption {
      type = lib.types.str;
      # VERIFY before the first install: read it from the UniFi gateway or
      # from `ip route` on skein while it still runs Ubuntu.
      default = "10.100.90.1";
      description = "Default gateway when lanAddress is set.";
    };

    lanNameservers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # loom and spindle, the patchwork.internal DCs. They answer for the
      # forest and forward everything else. Do not add a resolver from another
      # VLAN as a fallback: across the zone firewall it blackholes rather than
      # refuses, and every lookup waits for the timeout (see saker and the mrm
      # hosts in jaspermayone/infra).
      default = [
        "10.100.90.10"
        "10.100.90.11"
      ];
      description = "DNS servers for the lab interface.";
    };
  };

  config = {
    networking = {
      useDHCP = false;
      interfaces.ens18 =
        if cfg.lanAddress == null then
          { useDHCP = true; }
        else
          {
            ipv4.addresses = [
              {
                address = cfg.lanAddress;
                prefixLength = 24;
              }
            ];
          };
      defaultGateway = lib.mkIf (cfg.lanAddress != null) {
        address = cfg.lanGateway;
        interface = "ens18";
      };
      dhcpcd.wait = "background";
      dhcpcd.extraConfig = ''
        nooption domain_name_servers, domain_search
        clientid
      '';
      nameservers = cfg.lanNameservers;
      search = [ "patchwork.internal" ];
      firewall.enable = true;
    };

    time.timeZone = "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";

    boot.loader.grub.enable = true;

    users.mutableUsers = false;
    users.groups.admins = { };
    users.users = lib.genAttrs (cfg.admins ++ cfg.members) (
      name:
      {
        isNormalUser = true;
        shell = pkgs.zsh;
        openssh.authorizedKeys.keys = keys.${name};
      }
      // {
        extraGroups =
          lib.optionals (lib.elem name cfg.admins) [
            "wheel"
            "admins"
          ]
          ++ lib.optional config.virtualisation.docker.enable "docker";
      }
    );
    security.sudo.wheelNeedsPassword = false;
    programs.zsh.enable = true;

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    # agenix decrypts with the host key.
    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    services.qemuGuest.enable = true;

    services.tailscale = {
      enable = true;
      # MagicDNS would take /etc/resolv.conf, and the tailnet has no global
      # nameservers, so lab names would stop resolving. DNS comes from
      # lanNameservers. Same setting as saker and the mrm hosts.
      extraSetFlags = [ "--accept-dns=false", "--ssh" ];
    };

    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
    nix.optimise.automatic = true;
    nix.gc = {
      automatic = true;
      dates = "Sun *-*-* 04:00:00";
      randomizedDelaySec = "30m";
      options = "--delete-older-than 14d";
    };

    environment.systemPackages = with pkgs; [
      vim
      wget
      curl
      git
      htop
      tree
      jq
    ];
  };
}
