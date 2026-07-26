{
  description = "NixOS configuration for avocado (ZFS, disko, deployed via nixos-anywhere)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Used as: nix run github:nix-community/nixos-anywhere
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Third-party app deployed on the cluster (bingo.rithviknishad.dev). Pinned
    # source only (flake = false); built by pkgs/bingo. Bump: `just update
    # bingo-app`, then recompute npmDepsHash in pkgs/bingo/default.nix.
    bingo-app = {
      url = "github:sonzsara/bingo-app";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      ...
    }@inputs:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    in
    {
      nixosConfigurations.avocado = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          disko.nixosModules.disko
          ./hosts/avocado
        ];
      };

      # Standalone Home Manager config, so `nh home switch` works for
      # home-only iteration without a full `nixos-rebuild`. The same
      # ./home/rithviknishad module is also deployed system-wide via
      # modules/home-manager.nix during `nh os switch`.
      homeConfigurations."rithviknishad@avocado" = inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfree = true;
        };
        extraSpecialArgs = { inherit inputs; };
        modules = [ ./home/rithviknishad ];
      };

      # Buildable packages. `bingo-image` is the OCI tarball k3s preloads
      # (see modules/bingo.nix); `bingo-app` is the built app on its own.
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          bingo = pkgs.callPackage ./pkgs/bingo {
            src = inputs.bingo-app;
            version = inputs.bingo-app.shortRev or "dev";
            # vite 8 needs a recent Node; pin it rather than track the default.
            nodejs = pkgs.nodejs_22;
          };
        in
        {
          bingo-app = bingo.app;
        }
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          # dockerTools images build on Linux only.
          bingo-image = bingo.image;
        }
      );

      # `nix develop` — everything needed to work with this repo.
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.just
              pkgs.nixos-rebuild
              pkgs.sops
              pkgs.age
              pkgs.ssh-to-age
              pkgs.mkpasswd
              pkgs.nixfmt
              pkgs.git
              pkgs.cloudflared
              pkgs.kubectl
              pkgs.kubernetes-helm
              pkgs.helmfile
              inputs.nixos-anywhere.packages.${system}.default
            ];

            # Default the admin age key location so `sops` just works.
            # (Respects an already-set SOPS_AGE_KEY_FILE if you have one.)
            shellHook = ''
              export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
              echo "avocado devshell ready — tools: sops age ssh-to-age mkpasswd nixos-anywhere nixfmt cloudflared kubectl helm helmfile"
              echo "SOPS_AGE_KEY_FILE=$SOPS_AGE_KEY_FILE"
            '';
          };
        }
      );

      # `nix fmt`
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
