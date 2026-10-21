# batting — Quilt host (pve01 VMID 360, 10.100.90.60, 2 GB;
# VMID and address to be confirmed free before create)
#
# One app per VM. Sudo and the docker group are root here, so only the
# break-glass admins (modules/common) and lnx-batting-admins get them. Only this
# host's key decrypts the Quilt secrets.
# Public traffic arrives from alastor over the tailnet
# (nixosModules.edge-alastor) as plain HTTP to nginx on tailscale0:80.
#
# Tailnet tags: tag:patchwork (ssh from admins, port 80 from alastor) and
# tag:patchwork-quilt. The policy in jaspermayone/infra lets tag:patchwork-quilt
# reach seam:5432 (prod) only. hem (staging) gets a grant when it joins the tailnet.
#
# Bring-up: create the VM (terraform/proxmox), install with nixos-anywhere,
# tag the node with both tags, then add the host key to secrets/secrets.nix
# as a recipient of ad-join.age (AD logon) and run `agenix -r`.
# Quilt itself comes in a later change, with its secrets and its edge route.
{ ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
  ];

  networking.hostName = "batting";
  patchwork.lanAddress = "10.100.90.60";
  patchwork.banner.role = "quilt host";

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
