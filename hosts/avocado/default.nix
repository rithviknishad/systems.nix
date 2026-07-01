#
# Host: avocado
#
{ ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../../modules/base.nix
    ../../modules/ssh.nix
    ../../modules/nh.nix
    ../../modules/sops.nix
    ../../modules/zfs.nix
    ../../modules/desktop.nix
    ../../modules/home-manager.nix
    ../../modules/tailscale.nix
    ../../modules/k3s.nix
    ../../modules/monitoring.nix
    ../../modules/cloudflared.nix
    ../../users/rithviknishad.nix
  ];

  networking.hostName = "avocado";

  # Use NetworkManager (pulled in by the desktop module) for DHCP on all
  # interfaces, with a GUI widget in the GNOME shell.
  networking.networkmanager.enable = true;

  # The NixOS release this config was authored against. Do not change
  # casually after install — it governs stateful defaults.
  system.stateVersion = "26.11";
}
