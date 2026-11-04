#
# Tailscale, fully declarative.
#
# Auto-authenticates from a sops-managed auth key: `tailscale/auth-key` in the
# host's secrets/<hostname>.yaml (a reusable key from
# https://login.tailscale.com/admin/settings/keys — prefer a *tagged* one, so
# the node's key never expires and it can't silently drop off the tailnet).
# Without a valid key the autoconnect unit just fails harmlessly.
#
{ config, ... }:
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
    authKeyFile = config.sops.secrets."tailscale/auth-key".path;
  };

  sops.secrets."tailscale/auth-key" = { };

  # Let Tailscale traffic bypass the host firewall.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.checkReversePath = "loose";
}
