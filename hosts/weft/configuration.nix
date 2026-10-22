# weft — Krater host (pve01 VMID 361, 10.100.90.61, 4 GB, 40 GB disk)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-weft-admins get them. Only this
# host's key decrypts the Krater secrets.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-krater. The policy in jaspermayone/infra lets tag:patchwork-krater
# reach skein:5432 (prod) and hem:5432 (staging).
#
# Built on 2026-10-22 with `qm create`, `tofu import` and nixos-anywhere. Its
# host key is a recipient of ad-join.age (AD logon). Krater comes in #32.
{ ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
  ];

  networking.hostName = "weft";
  patchwork.lanAddress = "10.100.90.61";
  patchwork.banner.role = "krater host";

  virtualisation.docker.enable = true;

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    # Only alastor reaches this, over the tailnet. It already set
    # X-Forwarded-For and X-Forwarded-Proto; keep them.
    commonHttpConfig = ''
      set_real_ip_from 100.64.0.0/10;
      real_ip_header X-Forwarded-For;
    '';
  };
  # nginx is a host service, so the NixOS firewall applies to it (Docker's
  # published ports would bypass it). Open only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  system.stateVersion = "26.05";
}
