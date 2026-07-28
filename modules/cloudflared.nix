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
        # Monitoring stack (Traefik routes by Host to the k8s Ingresses):
        #   grafana -> grafana-ingress.yaml, status (Gatus) -> gatus.yaml.
        # Grafana is additionally protected by Cloudflare Access (Zero Trust);
        # see k8s/monitoring/README.md "Grafana SSO". VMSingle/VictoriaLogs are
        # deliberately NOT exposed here (no auth) — reach them via Tailscale.
        "grafana.rithviknishad.dev" = "http://localhost:80";
        "status.rithviknishad.dev" = "http://localhost:80";
        # ESPHome dashboard (k8s/esphome) — has NO auth of its own, so this
        # host must be gated by Cloudflare Access. Create the Access app
        # BEFORE running `cloudflared tunnel route dns avocado
        # esphome.rithviknishad.dev`, or the dashboard (which can flash
        # firmware onto devices) is wide open. See docs/esphome.md.
        "esphome.rithviknishad.dev" = "http://localhost:80";
        # Formance Ledger Console (k8s/formance) — micro-stack mode has NO
        # login of its own, so this host MUST be gated by Cloudflare Access.
        # Create the Access app BEFORE `cloudflared tunnel route dns avocado
        # ledger.rithviknishad.dev`. See docs/formance.md.
        "ledger.rithviknishad.dev" = "http://localhost:80";
        # Bingo multiplayer game (k8s/bingo) — public by design (party game).
        # Single-origin: the same host serves the SPA and the boardgame.io
        # websocket, which Traefik + this tunnel proxy without extra config.
        "bingo.rithviknishad.dev" = "http://localhost:80";
        # CARE HMIS + TeleICU (k8s/care, k8s/care-teleicu) — public by design
        # (CARE has its own auth). Hostnames are FLATTENED to one label:
        # Cloudflare's free Universal SSL cert only covers *.rithviknishad.dev,
        # so *.care.rithviknishad.dev would fail TLS at the edge.
        #   care      -> care_fe SPA        care-api -> Django API
        #   care-s3   -> MinIO (presigned upload/download URLs; Cloudflare's
        #                free-plan ~100MB request-body cap limits upload size)
        #   care-teleicu-gateway -> gateway nginx (streams + middleware)
        #   care-teleicu-devices -> devices micro-frontend (loaded by the SPA)
        "care.rithviknishad.dev" = "http://localhost:80";
        "care-api.rithviknishad.dev" = "http://localhost:80";
        "care-s3.rithviknishad.dev" = "http://localhost:80";
        "care-teleicu-gateway.rithviknishad.dev" = "http://localhost:80";
        "care-teleicu-devices.rithviknishad.dev" = "http://localhost:80";
        # Mock PTZ camera web UI (k8s/care-teleicu) — a throwaway ONVIF/RTSP
        # simulator with baked-in admin/admin Basic auth. Public by choice for
        # convenient demos; deliberately NOT Access-gated (unlike the sibling
        # tools below) because it holds nothing sensitive and only ever serves
        # a synthetic feed. See docs/care.md.
        "mock-ptz-camera.rithviknishad.dev" = "http://localhost:80";
        # ONVIF Camera Testing Console (k8s/onvif-console) — has NO auth of its
        # own and relays camera credentials, so this host MUST be gated by
        # Cloudflare Access. Create the Access app BEFORE `cloudflared tunnel
        # route dns avocado onvif-console.rithviknishad.dev`. See
        # docs/onvif-console.md.
        "onvif-console.rithviknishad.dev" = "http://localhost:80";
        # Kite Kubernetes dashboard (k8s/kite) — a full cluster-admin console.
        # Unlike the auth-less tools above, Kite gates itself with GitHub OAuth
        # (only the mapped GitHub user gets in), so this host does NOT need a
        # Cloudflare Access app in front. See docs/kite.md.
        "kite.rithviknishad.dev" = "http://localhost:80";
      };
    };
  };

  sops.secrets."cloudflared/credentials" = {
    sopsFile = ../secrets/cloudflared_credentials.json;
    format = "binary";
  };
}
