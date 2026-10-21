# weft — Krater host (pve01 VMID 361, 10.100.90.61, 2 GB;
# VMID and address to be confirmed free before create)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-weft-admins get them. Only this
# host's key decrypts the Krater secrets.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# The tailnet tag is tag:patchwork-krater. The policy in jaspermayone/infra lets
# that tag reach skein:5432 and hem:5432 only.
#
# Bring-up: create the VM (terraform/proxmox), install with nixos-anywhere,
# tag the node tag:patchwork-krater, then add the host key to secrets/secrets.nix.
# Krater itself comes in a later change, after the host key is a recipient.
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
