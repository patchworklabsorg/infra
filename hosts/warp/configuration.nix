# warp — Patchwork misc host (pve01 VMID 356, 10.100.90.56, 6 GB)
#
# Low-risk shared things, for example redirects. Not an app host: each app
# gets its own VM (batting for Quilt, weft for Krater), so an admin of one app
# cannot read the secrets of another. Weave stays on alastor.
#
# Public traffic arrives from alastor over the tailnet: alastor terminates TLS
# (nixosModules.edge-alastor) and sends plain HTTP to nginx on tailscale0:80,
# which routes by Host.
{ ... }:
{
  imports = [
    ../proxmox-vm.nix
    ../../modules/common
    ./redirects-nginx.nix
  ];

  networking.hostName = "warp";
  patchwork.lanAddress = "10.100.90.56";
  patchwork.banner.role = "misc host";
  patchwork.members = [ "dom" ];

  # No Docker: the docker group is root, and members (dom) must not be root
  # here. A thing that needs containers goes on its own VM.

  # Each thing that runs here adds its own virtual host.
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
