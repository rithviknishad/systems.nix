#
# Tailscale, fully declarative.
#
# Auto-authenticates from a sops-managed auth key: `tailscale/auth-key` in the
# host's secrets/<hostname>.yaml (a reusable key from
# https://login.tailscale.com/admin/settings/keys — prefer a *tagged* one, so
# the node's key never expires and it can't silently drop off the tailnet).
# Without a valid key the autoconnect unit just fails harmlessly.
#
# Package: the newer of our nixpkgs' tailscale and the one from the
# `nixpkgs-tailscale` flake input (a security bridge, see flake.nix). The
# version check makes the bridge a no-op as soon as the main pin catches up.
#
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  bridged = inputs.nixpkgs-tailscale.legacyPackages.${pkgs.stdenv.hostPlatform.system}.tailscale;
in
{
  services.tailscale = {
    enable = true;
    package =
      if lib.versionAtLeast pkgs.tailscale.version bridged.version then pkgs.tailscale else bridged;
    useRoutingFeatures = "both";
    authKeyFile = config.sops.secrets."tailscale/auth-key".path;
  };

  sops.secrets."tailscale/auth-key" = { };

  # Let Tailscale traffic bypass the host firewall.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.checkReversePath = "loose";
}
