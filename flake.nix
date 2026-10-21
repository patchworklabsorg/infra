{
  description = "Patchwork Labs declarative infra: hosts, shared NixOS modules and secrets";

  # This repo is public and must stay buildable by every org admin, so it never
  # takes jaspermayone/infra (private) as an input. The dependency goes the
  # other way: jaspermayone/infra imports nixosModules from here for alastor.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.darwin.follows = "";
      inputs.home-manager.follows = "";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      disko,
      deploy-rs,
      ...
    }:
    let
      tailnet = "wildebeest-stargazer.ts.net";

      # Lab VMs on pve01, VLAN 90. See README for the address plan.
      hosts = [
        "warp" # apps: Weave prod + staging, future apps
        "skein" # patchwork_central, prod
        "seam" # patchwork_central_restricted, prod
        "hem" # both staging clusters
      ];

      mkHost =
        name:
        nixpkgs.lib.nixosSystem {
          modules = [
            agenix.nixosModules.default
            disko.nixosModules.disko
            # On by default for the lab hosts. Not in nixosModules, so alastor
            # does not get it.
            ./modules/banner
            ./hosts/${name}/configuration.nix
          ];
        };
    in
    {
      nixosModules = {
        # The Weave service module alone, with no instance settings.
        weave = ./modules/weave;
        # Weave as it runs on alastor today: instance settings, deploy key,
        # Traefik routes and agenix secrets. Retire once Weave runs on warp.
        weave-alastor = ./hosts/alastor/weave.nix;
        # alastor as the public edge for apps on lab hosts. Replaces
        # weave-alastor on alastor after the move to warp.
        edge-alastor = ./hosts/alastor/edge.nix;
        # The Quilt service module alone, with no instance settings.
        quilt = ./modules/quilt;
        # Quilt on alastor: instance settings, Traefik route and agenix
        # secrets. Needs alastor's Tailscale to reach seam.
        quilt-alastor = ./hosts/alastor/quilt.nix;
        # alastor's Traefik route to the redirect server on warp
        # (hosts/warp/redirects.nix). Independent of edge-alastor.
        redirects-alastor = ./hosts/alastor/redirects.nix;
      };

      nixosConfigurations = nixpkgs.lib.genAttrs hosts mkHost;

      # deploy .#<host>. Over the tailnet, as on jaspermayone/infra's lab hosts.
      # Activation restarts sshd and tailscaled, which cuts the connection
      # deploy-rs confirms over, so magic rollback would always time out.
      deploy.nodes = nixpkgs.lib.genAttrs hosts (name: {
        hostname = "${name}.${tailnet}";
        magicRollback = false;
        autoRollback = false;
        profiles.system = {
          sshUser = "jsp";
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.${name};
        };
      });

      checks =
        nixpkgs.lib.recursiveUpdate
          (builtins.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib)
          (
            nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
              system:
              let
                pkgs = nixpkgs.legacyPackages.${system};
              in
              {
                ad-org = import ./tests/ad-org.nix {
                  inherit pkgs;
                  hosts = builtins.attrNames self.nixosConfigurations;
                };
                # Format check for every Terraform root. OpenTofu replaces
                # Terraform because Terraform is unfree. The format is the same.
                terraform-fmt =
                  pkgs.runCommand "terraform-fmt"
                    {
                      nativeBuildInputs = [ pkgs.opentofu ];
                      src = ./terraform;
                    }
                    ''
                      tofu fmt -check -recursive -diff $src
                      touch $out
                    '';
                # ansible/filter_plugins (vyos_split_secrets for thimble).
                ansible-filters =
                  pkgs.runCommand "ansible-filters"
                    {
                      nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.jinja2 ])) ];
                      src = ./ansible;
                    }
                    ''
                      cd $src
                      python3 -m unittest discover -s tests -v
                      touch $out
                    '';
              }
              // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
                central-db = import ./tests/central-db.nix { inherit pkgs; };
                banner = import ./tests/banner.nix {
                  inherit pkgs;
                  inherit (nixpkgs.lib) nixosSystem;
                  hosts = self.nixosConfigurations;
                  inherit (self) nixosModules;
                  agenixModule = agenix.nixosModules.default;
                };
                quilt-alastor = import ./tests/quilt-alastor.nix {
                  inherit pkgs;
                  inherit (nixpkgs.lib) nixosSystem;
                  module = self.nixosModules.quilt-alastor;
                  agenixModule = agenix.nixosModules.default;
                };
              }
            )
          );

      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.opentofu
              pkgs.google-cloud-sdk
              # agenix -e / -r, and bin/new-quilt-staging-secrets.
              agenix.packages.${system}.default
              pkgs.openssl
            ];
          };
        }
      );

      # The installer ISO for new VMs: root takes the admin keys, so
      # nixos-anywhere connects without a console login.
      # nix build .#installer-iso -o result-installer
      packages.x86_64-linux.installer-iso =
        (nixpkgs.lib.nixosSystem { modules = [ ./hosts/installer.nix ]; }).config.system.build.isoImage;

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;
      formatter.aarch64-linux = nixpkgs.legacyPackages.aarch64-linux.nixfmt-tree;
      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-tree;
    };
}
