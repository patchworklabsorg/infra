# Joins the host to the patchwork.internal AD forest with sssd. The NixOS
# copy of roles/linux_ad_join in jaspermayone/infra's Ansible, with the same
# rules, so a NixOS host and an Ubuntu host behave the same way:
#
#   - Only members of lnx-<host>-users may log in, and only by SSH key.
#     Keys come from the user's altSecurityIdentities ("SSHKey:<key>").
#   - Members of lnx-<host>-admins get sudo with their AD password.
#   - Both groups must exist in AD before the host joins. A group that does not
#     resolve denies every AD login and logs nothing. Local accounts
#     (modules/common) still work, so they are the way in to fix it.
#   - sssd does not update DNS. It would register Docker and Tailscale
#     addresses too. Add the host's A record in AD DNS by hand.
#   - The computer object goes in the Member-Servers OU.
#
# The join is one command and needs the svc-lnx-join password, so it runs once
# from ad-join.service: only when /etc/krb5.keytab is missing, and only when
# the password file exists. sssd starts after it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.patchwork.ad;
  host = config.networking.hostName;
  realm = lib.toUpper cfg.domain;
  secretFile = ../../secrets/ad-join.age;
in
{
  options.patchwork.ad = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Join patchwork.internal. Every Patchwork host does.";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "patchwork.internal";
    };

    dcs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # PDC emulator first, as in group_vars/patchwork.yml.
      default = [
        "loom.patchwork.internal"
        "spindle.patchwork.internal"
      ];
      description = "Domain controllers. They are also the KDCs and the time source.";
    };

    logonGroup = lib.mkOption {
      type = lib.types.str;
      default = "lnx-${host}-users";
      description = "AD group whose members may log in.";
    };

    sudoGroup = lib.mkOption {
      type = lib.types.str;
      default = "lnx-${host}-admins";
      description = "AD group whose members get sudo (with their AD password).";
    };

    computerOU = lib.mkOption {
      type = lib.types.str;
      default = "OU=Member-Servers,OU=Infrastructure,OU=Patchwork-Objects,DC=patchwork,DC=internal";
    };

    joinAccount = lib.mkOption {
      type = lib.types.str;
      default = "svc-lnx-join";
      description = "Account with join delegation on computerOU.";
    };

    joinPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if builtins.pathExists secretFile then config.age.secrets.ad-join.path else null;
      defaultText = lib.literalExpression "config.age.secrets.ad-join.path, when secrets/ad-join.age exists";
      description = "File with the joinAccount password only. null: join by hand.";
    };
  };

  config = lib.mkIf cfg.enable {
    age.secrets = lib.mkIf (builtins.pathExists secretFile) {
      ad-join.file = secretFile;
    };

    networking.domain = cfg.domain;
    # Kerberos refuses a clock more than 5 minutes off. Use the DCs, which the
    # rest of the forest uses too.
    networking.timeServers = cfg.dcs;

    security.krb5 = {
      enable = true;
      settings = {
        libdefaults = {
          default_realm = realm;
          dns_lookup_realm = false;
          dns_lookup_kdc = true;
          rdns = false;
          default_tkt_enctypes = "aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96";
          default_tgs_enctypes = "aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96";
          permitted_enctypes = "aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96";
        };
        realms.${realm} = {
          kdc = cfg.dcs;
          admin_server = builtins.head cfg.dcs;
          default_domain = cfg.domain;
        };
        domain_realm = {
          ".${cfg.domain}" = realm;
          ${cfg.domain} = realm;
        };
      };
    };

    environment.systemPackages = [ pkgs.adcli ];

    systemd.services.ad-join = {
      description = "Join ${cfg.domain}";
      wantedBy = [ "multi-user.target" ];
      before = [ "sssd.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.ConditionPathExists = "!/etc/krb5.keytab";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.adcli ];
      # --ldap-passwd: Server 2025 refuses SASL/GSSAPI for a password join.
      # --stdin-password keeps the password out of the process table.
      script =
        if cfg.joinPasswordFile == null then
          ''
            echo "ad-join: no join password file. Join by hand:" >&2
            echo "  adcli join ${cfg.domain} --login-user=${cfg.joinAccount} --computer-ou='${cfg.computerOU}' --host-fqdn=${host}.${cfg.domain} --ldap-passwd" >&2
            exit 1
          ''
        else
          ''
            # $(...) drops the trailing newline, which adcli would keep.
            printf '%s' "$(cat ${cfg.joinPasswordFile})" | adcli join ${cfg.domain} \
              --login-user=${cfg.joinAccount} \
              --computer-ou='${cfg.computerOU}' \
              --host-fqdn=${host}.${cfg.domain} \
              --ldap-passwd \
              --stdin-password
            adcli testjoin --domain=${cfg.domain}
          '';
    };

    services.sssd = {
      enable = true;
      config = ''
        [sssd]
        domains = ${cfg.domain}
        config_file_version = 2
        services = nss, pam, ssh

        [domain/${cfg.domain}]
        id_provider = ad
        auth_provider = ad
        chpass_provider = ad
        ad_domain = ${cfg.domain}
        krb5_realm = ${realm}
        ad_server = ${lib.concatStringsSep ", " cfg.dcs}
        cache_credentials = True
        krb5_store_password_if_offline = True
        ldap_id_mapping = True
        use_fully_qualified_names = False
        fallback_homedir = /home/%u
        default_shell = /run/current-system/sw/bin/bash
        dyndns_update = False
        ldap_user_extra_attrs = altSecurityIdentities:altSecurityIdentities
        ldap_user_ssh_public_key = altSecurityIdentities
        access_provider = simple
        simple_allow_groups = ${cfg.logonGroup}
      '';
    };
    systemd.services.sssd = {
      after = [ "ad-join.service" ];
      unitConfig.ConditionPathExists = "/etc/krb5.keytab";
    };

    # altSecurityIdentities also holds certificate mappings. Pass on only the
    # SSH keys. sshd refuses a command under /nix/store (group-writable), so
    # it goes in /etc, as services.sssd.sshAuthorizedKeysIntegration does.
    environment.etc."ssh/authorized_keys_command" = {
      mode = "0755";
      text = ''
        #!/bin/sh
        ${pkgs.sssd}/bin/sss_ssh_authorizedkeys "$1" | ${pkgs.gnused}/bin/sed -n 's/^SSHKey://p'
      '';
    };
    services.openssh = {
      authorizedKeysCommand = "/etc/ssh/authorized_keys_command";
      authorizedKeysCommandUser = "nobody";
    };

    # Without strict access, pam_unix accepts an AD user that sssd's
    # simple_allow_groups refused.
    security.pam.services.sshd = {
      sssdStrictAccess = true;
      makeHomeDir = true;
    };
    security.pam.services.login.sssdStrictAccess = true;

    security.sudo.extraRules = [
      {
        groups = [ cfg.sudoGroup ];
        commands = [ "ALL" ];
      }
    ];
  };
}
