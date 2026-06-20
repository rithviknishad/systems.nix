#
# Tailscale. After install, authenticate once with:
#   sudo tailscale up
# (or pass an auth key). The box already had a tailnet identity on Ubuntu;
# re-auth will issue a fresh node key.
#
{ ... }:
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };

  # Let Tailscale traffic bypass the host firewall.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.checkReversePath = "loose";
}
