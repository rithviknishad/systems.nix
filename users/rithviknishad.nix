#
# User: rithviknishad
#
{ pkgs, ... }:
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
    # The password hash (console/GUI login + sudo) is wired in modules/sops.nix,
    # next to the secret it comes from — so a host can import this user before
    # it has a sops key (a fresh nixos-anywhere install). Until then the
    # account is SSH-key only and root's key (below) does the admin work.
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
