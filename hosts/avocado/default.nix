#
# Host: avocado
#
{ ... }:
{
  imports = [
    ./hardware.nix
    ./aarch64-builder.nix
    ./disko.nix
    ../../modules/base.nix
    ../../modules/ssh.nix
    ../../modules/nh.nix
    ../../modules/sops.nix
    ../../modules/zfs.nix
    ../../modules/kiosk.nix
    ../../modules/home-manager.nix
    ../../modules/tailscale.nix
    ../../modules/k3s.nix
    ../../modules/monitoring.nix
    ../../modules/cloudflared.nix
    ../../modules/docker.nix
    ../../modules/esphome.nix
    ../../modules/bingo.nix
    ../../users/rithviknishad.nix
  ];

  networking.hostName = "avocado";

  # NetworkManager for DHCP on all interfaces (was pulled in by the old GNOME
  # desktop; now enabled explicitly — `nmcli`/`nmtui` over SSH).
  networking.networkmanager.enable = true;

  # The NixOS release this config was authored against. Do not change
  # casually after install — it governs stateful defaults.
  system.stateVersion = "26.11";
}
