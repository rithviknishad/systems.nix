#
# Home Manager, integrated as a NixOS module so it deploys with `nixos-rebuild`.
#
{ inputs, ... }:
{
  imports = [ inputs.home-manager.nixosModules.home-manager ];

  # rithviknishad's SSH private key (own binary sops file), used by the Home
  # Manager ssh module (home/rithviknishad/apps/ssh) as its identityFile.
  # Declared here, next to its only consumer, so a host only needs this key
  # in .sops.yaml (secrets/ssh_id_ed25519) once it runs Home Manager.
  sops.secrets."rithviknishad/ssh_id_ed25519" = {
    sopsFile = ../secrets/ssh_id_ed25519;
    format = "binary";
    owner = "rithviknishad";
    group = "users";
    mode = "0600";
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; };
    # Don't fail activation if a dotfile already exists; back it up instead.
    backupFileExtension = "hm-bak";

    users.rithviknishad = import ../home/rithviknishad;
  };
}
