#
# k3s — settings shared by every node (server and agents).
#
# Cluster traffic runs over the TAILNET, not the LAN: the router can't do DHCP
# reservations, so LAN addresses may move, while a node's Tailscale IP is
# stable for as long as it stays registered. Each node advertises its
# tailscale0 IPv4 as its node-ip and runs flannel's VXLAN over tailscale0
# (WireGuard underneath, so pod traffic between nodes is encrypted too).
# tailscale0 is a trusted firewall interface (modules/tailscale.nix), so no
# k3s ports need opening for node-to-node traffic.
#
# Why node-ip is written at start-up instead of set statically:
#   - `--flannel-iface=tailscale0` alone would make k3s derive node-ip from
#     the interface, but tailscale0 also carries an IPv6 address and k3s then
#     returns "v4,v6" — i.e. a dual-stack node in an IPv4-only cluster.
#   - Hardcoding the 100.x address per host breaks silently on a reinstall
#     (a fresh node registration gets a fresh Tailscale IP).
# So ExecStartPre waits for tailscale0's IPv4 and writes it to a k3s config
# file under /run. Tradeoff: k3s now needs tailscaled up with an address
# before it starts; until then it retries (Restart=always) rather than coming
# up on the wrong address.
#
{
  config,
  pkgs,
  ...
}:
let
  nodeIpConfig = "/run/k3s/node-ip.yaml";

  writeNodeIp = pkgs.writeShellScript "k3s-write-node-ip" ''
    set -eu
    ip=""
    for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
      ip="$(${pkgs.iproute2}/bin/ip -4 -o addr show dev tailscale0 2>/dev/null \
        | ${pkgs.gawk}/bin/awk '{ split($4, a, "/"); print a[1]; exit }')"
      [ -n "$ip" ] && break
      ${pkgs.coreutils}/bin/sleep 2
    done
    if [ -z "$ip" ]; then
      echo "k3s: tailscale0 has no IPv4 address after 120s; is tailscaled up?" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname ${nodeIpConfig})"
    printf 'node-ip: %s\n' "$ip" > ${nodeIpConfig}
    echo "k3s: node-ip $ip (tailscale0)"
  '';
in
{
  services.k3s = {
    enable = true;
    tokenFile = config.sops.secrets."k3s/token".path;
    configPath = nodeIpConfig;
    extraFlags = [ "--flannel-iface=tailscale0" ];
  };

  # The shared cluster join token, from the host's own secrets/<hostname>.yaml.
  sops.secrets."k3s/token" = { };

  systemd.services.k3s = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    # Restart k3s whenever tailscaled is stopped/restarted (e.g. by a switch
    # that upgrades tailscale). flannel's VXLAN device (flannel.1) is created
    # *on* tailscale0, and the kernel deletes it when tailscale0 goes away;
    # flannel only recreates it at k3s start. Without this, a tailscale
    # upgrade on 2026-11-04 silently broke all cross-node pod traffic on
    # every node while host-network checks stayed green. Cheap: KillMode is
    # `process`, so pods keep running across a k3s restart (on avocado the
    # API server blips for ~30s). PartOf covers explicit stops/restarts; for
    # anything else that recreates tailscale0 (a crash, a manual `ip link`),
    # TargetDown on the agents' Vector pods (scraped over pod IPs) catches it.
    partOf = [ "tailscaled.service" ];
    serviceConfig.ExecStartPre = [ writeNodeIp ];
  };
}
