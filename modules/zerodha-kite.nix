#
# zerodha-kite host-side concerns: (1) preload the Nix-built image into k3s,
# and (2) put Tailscale HTTPS in front of it.
#
# (1) Image preload — same no-registry pattern as modules/bingo.nix. The
# k8s/zerodha-kite workload runs `zerodha-kite:latest` with imagePullPolicy:
# IfNotPresent and no registry; services.k3s.images links the OCI tarball into
# k3s's imageDir and the agent imports it into containerd before workloads
# start.
#
# Updating the server: `just update kite-mcp-server` (+ recompute vendorHash in
# pkgs/zerodha-kite/default.nix if go.sum changed), then `just deploy` —
# activation restarts k3s so the new tarball is re-imported — followed by
# `just zerodha-kite-deploy` to roll the pod onto the refreshed :latest.
#
# (2) Tailscale HTTPS front door — WHY this exists: the Kite Connect app's
# Redirect URL must be **HTTPS** (the console rejects http://). The pod only
# speaks plain HTTP on NodePort 30080. So we terminate TLS with Tailscale's own
# Let's Encrypt cert for the box's MagicDNS name and proxy to the NodePort:
#
#   https://avocado.<tailnet>.ts.net:8443  ->  http://<box tailscale IP>:30080
#
# WHY port 8443 (not 443): k3s's klipper svclb already binds host :80/:443 for
# Traefik (the public ingress), so 443 is taken. Tailscale `serve` allows HTTPS
# on 443, 8443, or 10000 — 8443 is free, and the Kite console accepts an HTTPS
# redirect URL with that explicit port. The result stays tailnet-only (the
# MagicDNS name resolves only inside the tailnet) with a browser-trusted cert.
#
# WHY a systemd oneshot re-asserting `serve --bg`: `tailscale serve` persists
# its config in tailscaled state, but re-running on every activation keeps the
# repo the source of truth (idempotent) and re-points the proxy if the box's
# tailscale IP ever changes.
{
  inputs,
  pkgs,
  config,
  ...
}:
let
  tailscale = config.services.tailscale.package;
  # Proxy HTTPS/8443 to the pinned NodePort. Resolve the box's own tailscale
  # IPv4 at start (NodePort binds every node IP incl. tailscale0; loopback does
  # not work for NodePort, so we target the tailscale IP explicitly).
  serveScript = pkgs.writeShellScript "zerodha-kite-tailscale-serve" ''
    set -eu
    ip=""
    for _ in $(seq 1 30); do
      ip=$(${tailscale}/bin/tailscale ip -4 2>/dev/null || true)
      [ -n "$ip" ] && break
      sleep 2
    done
    if [ -z "$ip" ]; then
      echo "zerodha-kite serve: no tailscale IPv4 yet, giving up" >&2
      exit 1
    fi
    ${tailscale}/bin/tailscale serve --bg --https=8443 "http://$ip:30080"
  '';
in
{
  services.k3s.images = [
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.zerodha-kite-image
  ];

  systemd.services.zerodha-kite-tailscale-serve = {
    description = "Expose zerodha-kite (NodePort 30080) over Tailscale HTTPS :8443";
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "k3s.service"
    ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = serveScript;
      # Best-effort teardown of just this port's proxy (no-op if already off).
      ExecStop = "${tailscale}/bin/tailscale serve --https=8443 off";
    };
  };
}
