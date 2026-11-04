#
# Host: g8way (Intel NUC5i3RYB, was Linux Mint "nuc")
#
# Role: k3s *agent* (worker) + jumpbox — a Cinnamon desktop with the tooling to
# watch and poke the cluster whose control plane stays on avocado. Built up in
# layers so a broken one never costs a reinstall (see docs/nodes.md).
# Layers so far: minimal base (SSH, ZFS, user, mDNS) + sops (secrets/g8way.yaml,
# decrypted via the SSH host key) + tailscale + the desktop/jumpbox layer:
# Cinnamon on LightDM, Intel VA-API (./hardware.nix), cluster tools and the
# admin kubeconfig (modules/jumpbox.nix), Home Manager (which brings the
# user's SSH key), and nh. Plus k3s agent (modules/k3s-agent.nix): joins
# avocado over the tailnet, tainted so workloads only land here by opting in.
# Plus host ZFS/SMART metrics for node-exporter (modules/monitoring.nix).
#
# LAN NIC: enp0s25 (Intel I218-V, MAC 94:c6:91:14:ea:af). DHCP with no router
# reservation — if the address moves, find it again by MAC:
#   nmap -sn 192.168.165.0/24 | grep -i -B2 94:c6:91:14:ea:af
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
    ../../modules/desktop-cinnamon.nix
    ../../modules/jumpbox.nix
    ../../modules/home-manager.nix
    # nh expects the repo cloned at ~/systems.nix (one-time manual clone, done
    # 2026-11-04; see docs/nodes.md). `git pull` there before `nh os switch`.
    ../../modules/nh.nix
    ../../modules/k3s-agent.nix
    # Host ZFS + SMART textfile metrics for node-exporter (docs/monitoring.md).
    ../../modules/monitoring.nix
    ../../users/rithviknishad.nix
  ];

  networking.hostName = "g8way";

  # NetworkManager: DHCP on Ethernet, and Wi-Fi via Cinnamon's network applet.
  networking.networkmanager.enable = true;

  # mDNS on the LAN NIC only (see modules/avahi.nix) — `g8way.local`.
  services.avahi.allowInterfaces = [ "enp0s25" ];

  # A desktop that's also a k3s node: Cinnamon's power manager may
  # idle-suspend it, which drops the node off the network and looks exactly
  # like a crash. Remove the sleep targets so nothing can suspend it.
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
