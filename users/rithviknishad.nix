#
# User: rithviknishad
#
{ config, pkgs, ... }:
{
  users.mutableUsers = false;

  # zsh is configured per-user via Home Manager; enable it at the system
  # level so it can be a valid login shell.
  programs.zsh.enable = true;

  users.users.rithviknishad = {
    isNormalUser = true;
    description = "Rithvik Nishad";
    extraGroups = [
      "wheel"
      "networkmanager"
      "dialout"
    ];
    shell = pkgs.zsh;
    # Password hash comes from sops (secrets/avocado.yaml). Enables console
    # login + sudo. Edit it with: sops secrets/avocado.yaml
    hashedPasswordFile = config.sops.secrets."users/rithviknishad/hashed-password".path;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPaqSwO7pnIjLIbiR2ApU8s73EI8Sya/Kd0orKci8dSh"
      # tellmeY18 (github.com/tellmeY18.keys)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoUJulOP9ZLy8Ny2LgS6HT7WSg93a4eHwbA412LbOR5"
    ];
  };

  # Root can also be reached with the same key (used by nixos-anywhere).
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPaqSwO7pnIjLIbiR2ApU8s73EI8Sya/Kd0orKci8dSh"
    # tellmeY18 (github.com/tellmeY18.keys)
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOoUJulOP9ZLy8Ny2LgS6HT7WSg93a4eHwbA412LbOR5"
  ];
}
