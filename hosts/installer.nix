# The Patchwork installer ISO. It is the stock NixOS minimal ISO with the
# admin SSH keys on root, so nixos-anywhere can connect at once. Nobody types
# in the Proxmox console. Build it with `nix build .#installer-iso`.
#
# The guest agent lets Proxmox and Terraform read the DHCP address.
{ lib, modulesPath, ... }:
let
  keys = import ../modules/common/keys.nix;
  admins = [
    "jsp"
    "krn"
    "yc"
  ];
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  users.users.root.openssh.authorizedKeys.keys = lib.concatMap (name: keys.${name}) admins;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.qemuGuest.enable = true;

  # The ISO file is iso/patchwork-nixos-installer.iso.
  image.baseName = lib.mkForce "patchwork-nixos-installer";

  nixpkgs.hostPlatform = "x86_64-linux";
}
