#
# ESPHome (runs in k3s — see k8s/esphome/) — host-side networking support.
#
# The dashboard pod uses hostNetwork so it can discover ESP devices and track
# their online status over mDNS, and push OTA updates on the LAN. mDNS
# responses arrive as inbound UDP on 5353, which the firewall would otherwise
# drop. The dashboard port itself (6052) stays CLOSED on the LAN on purpose —
# the UI has no auth. Reach it over Tailscale (trusted interface) or the
# Cloudflare Tunnel (gated by Cloudflare Access).
#
{ ... }:
{
  networking.firewall.allowedUDPPorts = [
    5353 # mDNS — ESPHome device discovery / online status
  ];
}
