#
# Home Manager, integrated as a NixOS module so it deploys with `nixos-rebuild`.
#
{ inputs, ... }:
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    # Don't fail activation if a dotfile already exists; back it up instead.
    backupFileExtension = "hm-bak";

    users.rithviknishad = import ../home/rithviknishad;
  };
}
