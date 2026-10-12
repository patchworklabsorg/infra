# Hardware and disk layout shared by every Patchwork VM on pve01: SeaBIOS,
# one virtio-scsi disk at /dev/sda, GPT with a BIOS boot partition, ext4 root.
# Same shape as saker and the mrm hosts in jaspermayone/infra.
#
# Create the VM with `cpu: host` and the QEMU guest agent on. Install with
# nixos-anywhere (it runs disko), then commit the host key to secrets.nix.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  nixpkgs.hostPlatform = "x86_64-linux";
}
