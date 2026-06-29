#
# Cloudflare Tunnel — exposes services without a static IP or open ports.
#
# cloudflared dials OUT to Cloudflare, so nothing is exposed on avocado.
# Public subdomains of rithviknishad.dev resolve to the tunnel, which forwards
# to Traefik (k3s ingress) on :80; Traefik routes by Host. TLS terminates at
# Cloudflare's edge, so no cert-manager needed to start.
#
# One-time setup (from this repo, in `nix develop`):
#   1. cloudflared tunnel login
#   2. cloudflared tunnel create avocado        # prints a tunnel UUID + creds json
#   3. put the creds json into secrets/cloudflared_credentials.json via sops
#      (binary): sops --input-type binary --output-type binary -e <json> > ...
#   4. set TUNNEL_ID below to the UUID
#   5. cloudflared tunnel route dns avocado photos.rithviknishad.dev  (per host)
#
{ config, ... }:
let
  tunnelId = "41180798-4793-474b-847e-3ad36a30df2f";
in
{
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = config.sops.secrets."cloudflared/credentials".path;
      default = "http_status:404";
      ingress = {
        # Each public host -> Traefik. Add more lines as you add services.
        "hello.rithviknishad.dev" = "http://localhost:80";
        "photos.rithviknishad.dev" = "http://localhost:80";
      };
    };
  };

  sops.secrets."cloudflared/credentials" = {
    sopsFile = ../secrets/cloudflared_credentials.json;
    format = "binary";
  };
}
