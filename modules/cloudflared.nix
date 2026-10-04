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
        # Grafana is NOT behind Cloudflare Access — its own login (sops admin
        # password) is the only gate. VMSingle/VictoriaLogs are deliberately
        # NOT exposed here (no auth) — reach them via Tailscale.
        "grafana.rithviknishad.dev" = "http://localhost:80";
        "status.rithviknishad.dev" = "http://localhost:80";

        # CARE HMIS + TeleICU (k8s/care, k8s/care-teleicu) — public by design
        # (CARE has its own auth). Hostnames are FLATTENED to one label:
        # Cloudflare's free Universal SSL cert only covers *.rithviknishad.dev,
        # so *.care.rithviknishad.dev would fail TLS at the edge.
        #   care      -> ONE origin, path-routed by Traefik: SPA, /api (incl.
        #                ABDM callbacks), /mfe-plugs/abdm, and the VersityGW
        #                buckets for presigned URLs (Cloudflare's free-plan
        #                ~100MB request-body cap limits upload size)
        #   care-api  -> Django API (TeleICU gateway's CARE_API, Django admin)
        #   care-teleicu-gateway -> gateway nginx (streams + middleware)
        #   care-teleicu-devices -> devices micro-frontend (loaded by the SPA)
        "care.rithviknishad.dev" = "http://localhost:80";
        "care-api.rithviknishad.dev" = "http://localhost:80";
        "care-teleicu-gateway.rithviknishad.dev" = "http://localhost:80";
        "care-teleicu-devices.rithviknishad.dev" = "http://localhost:80";
        # Mock PTZ camera web UI (k8s/care-teleicu) — a throwaway ONVIF/RTSP
        # simulator with baked-in admin/admin Basic auth. Public by choice for
        # convenient demos; deliberately NOT Access-gated (unlike
        # onvif-console below) because it holds nothing sensitive and only ever serves
        # a synthetic feed. See docs/care.md.
        "mock-ptz-camera.rithviknishad.dev" = "http://localhost:80";
        # ONVIF Camera Testing Console (k8s/onvif-console) — has NO auth of its
        # own and relays camera credentials, so this host MUST be gated by
        # Cloudflare Access. Create the Access app BEFORE `cloudflared tunnel
        # route dns avocado onvif-console.rithviknishad.dev`. See
        # docs/onvif-console.md.
        "onvif-console.rithviknishad.dev" = "http://localhost:80";
        # Kite Kubernetes dashboard (k8s/kite) — a full cluster-admin console.
        # Unlike the auth-less onvif-console above, Kite gates itself with GitHub OAuth
        # (only the mapped GitHub user gets in), so this host does NOT need a
        # Cloudflare Access app in front. See docs/kite.md.
        "kite.rithviknishad.dev" = "http://localhost:80";

        # suchi document archive (k8s/suchi) — public by design: the Suchi
        # Companion mobile app and API-token clients talk to it from anywhere.
        # suchi gates everything with its own accounts (/metrics is admin-only),
        # so NO Cloudflare Access gate — an SSO wall would break the app's API
        # calls. See docs/suchi.md.
        "suchi.rithviknishad.dev" = "http://localhost:80";

        # Mailpit test-mail inbox (k8s/mailpit) — public by choice: it only
        # ever holds TEST mail. Mailpit's own basic auth (ui-auth) gates the UI
        # and API, so no Cloudflare Access app. Only the inbox is public; SMTP
        # can't ride this tunnel for anonymous clients. See docs/mailpit.md.
        "mailpit.rithviknishad.dev" = "http://localhost:80";
      };
    };
  };

  # Survive transient DNS outages.
  #
  # cloudflared resolves argotunnel.com at startup and exits within ~1s if that
  # fails. With systemd's defaults (RestartSec=100ms plus a start limit of 5
  # starts per 10s) a tunnel that crash-loops on DNS burns every attempt in ~4
  # seconds, after which systemd gives up *permanently* — the tunnel then stays
  # down until a human notices, long after DNS has recovered.
  #
  # That is exactly how every public host served Cloudflare Error 1033 for over
  # an hour on 2026-09-16: a `just deploy` restarted cloudflared during a window
  # where MagicDNS had no upstream resolvers (a DHCP blip left tailscaled
  # forwarding to nothing, so every public name SERVFAILed), the unit hit
  # start-limit-hit, and it never came back on its own.
  #
  # Backing off slower and never giving up turns that class of blip into a few
  # seconds of downtime instead of an outage that needs manual intervention.
  systemd.services."cloudflared-tunnel-${tunnelId}" = {
    startLimitIntervalSec = 0; # no start-rate limit: keep retrying forever
    serviceConfig.RestartSec = 10;
  };

  sops.secrets."cloudflared/credentials" = {
    sopsFile = ../secrets/cloudflared_credentials.json;
    format = "binary";
  };
}
