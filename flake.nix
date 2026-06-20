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
              inputs.nixos-anywhere.packages.${system}.default
            ];

            # Default the admin age key location so `sops` just works.
            # (Respects an already-set SOPS_AGE_KEY_FILE if you have one.)
            shellHook = ''
              export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
              echo "avocado devshell ready — tools: sops age ssh-to-age mkpasswd nixos-anywhere nixfmt"
              echo "SOPS_AGE_KEY_FILE=$SOPS_AGE_KEY_FILE"
            '';
          };
        }
      );

      # `nix fmt`
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
