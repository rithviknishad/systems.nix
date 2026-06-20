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
    ../../modules/sops.nix
    ../../modules/zfs.nix
    ../../modules/desktop.nix
    ../../modules/tailscale.nix
    ../../users/rithviknishad.nix
  ];

  networking.hostName = "avocado";

  # Primary LAN NIC uses DHCP (matches the current Ubuntu setup).
  networking.useDHCP = false;
  networking.interfaces.enp2s0.useDHCP = true;

  # The NixOS release this config was authored against. Do not change
  # casually after install — it governs stateful defaults.
  system.stateVersion = "26.11";
}
