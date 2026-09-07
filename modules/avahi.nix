#
# mDNS responder — makes the box answer to `avocado.local` on the LAN.
#
# Why: nothing published that name before. `avocado` is a Tailscale MagicDNS
# name and resolves only inside the tailnet, and the LAN has no DNS record for
# the box (DHCP address, no local zone), so LAN clients had no name to reach it
# by at all. Avahi answers multicast queries for `avocado.local`, which macOS,
# iOS, Android and systemd-resolved clients all resolve without any client-side
# setup — no more /etc/hosts entries.
#
{ ... }:
{
  services.avahi = {
    enable = true;

    # Opens UDP 5353. esphome.nix also opens it (so mDNS replies from ESP
    # devices reach that pod); both stay self-contained rather than one
    # module depending on the other's rule.
    openFirewall = true;

    # Publish this host's own A/AAAA records, nothing more. `workstation` and
    # `userServices` would advertise extra service records nothing here uses.
    #
    # Note this covers the host name only: mDNS has no notion of subdomains,
    # so the `*.avocado.local` Traefik ingress hosts are NOT resolved by this
    # and still need LAN DNS or /etc/hosts (see docs/networking.md).
    publish = {
      enable = true;
      addresses = true;
    };

    # LAN interface only. Multicast never crosses Tailscale, and publishing on
    # the k8s/docker bridges would advertise 10.42.x/172.17.x addresses that
    # are unreachable from anywhere that matters.
    allowInterfaces = [ "enp2s0" ];

    # Let the box resolve other *.local names too — the other half of an
    # iperf3 run is `iperf3 -c <peer>.local` from avocado.
    #
    # Gotcha: nss-mdns claims the whole `.local` domain, which textually
    # includes k8s's `cluster.local`. Harmless here — the host has never
    # resolved cluster.local (pods use CoreDNS, not the host's nsswitch).
    nssmdns4 = true;
  };
}
