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
    ../../modules/avahi.nix
    ../../modules/iperf.nix
    ../../modules/kiosk.nix
    ../../modules/home-manager.nix
    ../../modules/tailscale.nix
    ../../modules/k3s.nix
    ../../modules/monitoring.nix
    ../../modules/cloudflared.nix
    ../../modules/docker.nix
    ../../modules/care-box.nix

    ../../modules/zerodha-kite.nix
    ../../modules/settle-up-mcp.nix
    ../../users/rithviknishad.nix
  ];

  networking.hostName = "avocado";

  # NetworkManager for DHCP on all interfaces (was pulled in by the old GNOME
  # desktop; now enabled explicitly — `nmcli`/`nmtui` over SSH).
  networking.networkmanager.enable = true;

  # mDNS on the LAN NIC only (see modules/avahi.nix).
  services.avahi.allowInterfaces = [ "enp2s0" ];

  # sops: avocado decrypts with a dedicated age key provisioned out-of-band
  # (never in the repo), not its SSH host key — see modules/sops.nix.
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    generateKey = false;
  };

  # The NixOS release this config was authored against. Do not change
  # casually after install — it governs stateful defaults.
  system.stateVersion = "26.11";
}
