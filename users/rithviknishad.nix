#
# User: rithviknishad
#
{ pkgs, ... }:
{
  users.mutableUsers = false;

  users.users.rithviknishad = {
    isNormalUser = true;
    description = "Rithvik Nishad";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPaqSwO7pnIjLIbiR2ApU8s73EI8Sya/Kd0orKci8dSh"
    ];
  };

  # wheel can sudo. Set a password after install with `passwd`, or keep
  # key-only + passwordless sudo by uncommenting below.
  # security.sudo.wheelNeedsPassword = false;

  # Root can also be reached with the same key (used by nixos-anywhere).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPaqSwO7pnIjLIbiR2ApU8s73EI8Sya/Kd0orKci8dSh"
  ];
}
