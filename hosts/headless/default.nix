#
# Host: headless (HP 348 G7 laptop, was Linux Mint "minty")
#
# Role: k3s *agent* (worker), no display. Treated as DISPOSABLE: its only SSD
# fails SMART (see ./disko.nix), so nothing stateful is scheduled here.
# Layers so far: minimal base (SSH, ZFS, user, mDNS) + sops (secrets/headless.yaml,
# decrypted via the SSH host key) + tailscale + k3s agent (modules/k3s-agent.nix:
# joins avocado over the tailnet, tainted so workloads only land here by
# opting in; see docs/nodes.md) + host ZFS/SMART metrics (modules/monitoring.nix).
#
# LAN NIC: enp1s0 (Realtek RTL8111, MAC 38:22:e2:ed:12:21). DHCP with no router
# reservation — if the address moves, find it again by MAC:
#   nmap -sn 192.168.165.0/24 | grep -i -B2 38:22:e2:ed:12:21
#
{ ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
    ../../modules/base.nix
    ../../modules/ssh.nix
    ../../modules/zfs.nix
    ../../modules/avahi.nix
    ../../modules/sops.nix
    ../../modules/tailscale.nix
    ../../modules/k3s-agent.nix
    # Host ZFS + SMART textfile metrics for node-exporter (docs/monitoring.md).
    ../../modules/monitoring.nix
    ../../users/rithviknishad.nix
  ];

  networking.hostName = "headless";

  # The Samsung PM951 fails SMART for good (103% of rated endurance used,
  # critical warning 0x04 "reliability degraded") and we've chosen to run it
  # into the ground. Acknowledge it so SmartDeviceUnhealthy doesn't page
  # forever; SmartNvme* still fire if it degrades further (spare below
  # threshold, read-only, new media errors) — the cue to drain the node.
  systems.monitoring.smart.acknowledgedFailingSerials = [ "S29NNXAH395193" ];

  networking.networkmanager.enable = true;

  # mDNS on the LAN NIC only (see modules/avahi.nix) — `headless.local`.
  services.avahi.allowInterfaces = [ "enp1s0" ];

  # It's a laptop running as a server: logind suspends on lid close by default
  # (even with no desktop), which takes the node off the network and looks
  # exactly like a crash. Ignore the lid in every power state, and remove the
  # sleep targets outright so nothing else can suspend it either.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };
  systemd.targets = {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    hybrid-sleep.enable = false;
  };

  # The NixOS release this config was authored against. Do not change
  # casually after install — it governs stateful defaults.
  system.stateVersion = "26.11";
}
