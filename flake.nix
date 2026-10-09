{
  description = "Patchwork Labs declarative infra: shared NixOS modules and secrets";

  # This repo is public and must stay buildable by every org admin, so it never
  # takes jaspermayone/infra (private) as an input. The dependency goes the
  # other way: jaspermayone/infra and patchworklabsorg/core import from here.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };

  outputs =
    { nixpkgs, ... }:
    {
      nixosModules = {
        # The Weave service module alone, with no instance settings.
        weave = ./modules/weave;
        # Weave as it runs on alastor: instance settings, deploy key, Traefik
        # routes and agenix secrets. jaspermayone/infra's alastor imports it.
        weave-alastor = ./hosts/alastor/weave.nix;
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixfmt-tree;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };
}
