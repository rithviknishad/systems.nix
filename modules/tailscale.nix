#
# Tailscale, fully declarative.
#
# Auto-authenticates from a sops-managed auth key. Put a real key in
# secrets/avocado.yaml under tailscale/auth-key (a reusable/ephemeral key
# from https://login.tailscale.com/admin/settings/keys). Until then the
# autoconnect unit just fails harmlessly.
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
