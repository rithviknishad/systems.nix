#
# iperf3 — network throughput testing.
#
# The client CLI plus an always-on server, so any machine on the LAN or the
# tailnet can just run `iperf3 -c avocado.local` without first SSH-ing in to
# start `iperf3 -s` by hand. The name comes from avahi.nix.
#
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.iperf3 ];

  services.iperf3 = {
    enable = true;
    openFirewall = true;
  };

  # `openFirewall` opens the TCP port only. UDP tests (`iperf3 -u`) negotiate
  # over TCP 5201 but carry their data on UDP 5201, which would be dropped.
  networking.firewall.allowedUDPPorts = [ 5201 ];
}
