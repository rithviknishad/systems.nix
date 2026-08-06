#
# settle-up-mcp host-side concern: put Tailscale HTTPS in front of the k8s
# workload (k8s/settle-up-mcp).
#
# Unlike modules/zerodha-kite.nix there is NO image preload here — the server is
# our own upstream repo (github:rithviknishad/settle-up-mcp) publishing a
# multi-arch image to GHCR, so the pod pulls `:latest` from the registry and
# upgrades are a plain `just settle-up-mcp-deploy` (no flake input, no rebuild).
#
# Tailscale HTTPS front door — WHY this exists: the pod only speaks plain HTTP
# on NodePort 30800. MCP clients want a real HTTPS endpoint (otherwise bridges
# like mcp-remote need --allow-http), and the static bearer token should not
# cross even the tailnet in the clear. So we terminate TLS with Tailscale's own
# Let's Encrypt cert for the box's MagicDNS name and proxy to the NodePort:
#
#   https://avocado.<tailnet>.ts.net:10000  ->  http://<box tailscale IP>:30800
#
# WHY port 10000: `tailscale serve` only allows HTTPS on 443, 8443 or 10000.
# k3s's klipper svclb owns host :443 for Traefik (the public ingress) and
# modules/zerodha-kite.nix already took :8443 — 10000 is the last free one. A
# third tailnet HTTPS service will need path-based serve routes under an
# existing port rather than a fourth port.
#
# The result stays tailnet-only: the MagicDNS name resolves only inside the
# tailnet, and the NodePort range is not in the host's allowedTCPPorts
# (modules/k3s.nix), so nothing here is reachable on WAN/LAN.
#
# WHY a systemd oneshot re-asserting `serve --bg`: `tailscale serve` persists
# its config in tailscaled state, but re-running on every activation keeps the
# repo the source of truth (idempotent) and re-points the proxy if the box's
# tailscale IP ever changes.
{
  pkgs,
  config,
  ...
}:
let
  tailscale = config.services.tailscale.package;
  # Proxy HTTPS/10000 to the pinned NodePort. Resolve the box's own tailscale
  # IPv4 at start (NodePort binds every node IP incl. tailscale0; loopback does
  # not work for NodePort, so we target the tailscale IP explicitly).
  serveScript = pkgs.writeShellScript "settle-up-mcp-tailscale-serve" ''
    set -eu
    ip=""
    for _ in $(seq 1 30); do
      ip=$(${tailscale}/bin/tailscale ip -4 2>/dev/null || true)
      [ -n "$ip" ] && break
      sleep 2
    done
    if [ -z "$ip" ]; then
      echo "settle-up-mcp serve: no tailscale IPv4 yet, giving up" >&2
      exit 1
    fi
    ${tailscale}/bin/tailscale serve --bg --https=10000 "http://$ip:30800"
  '';
in
{
  systemd.services.settle-up-mcp-tailscale-serve = {
    description = "Expose settle-up-mcp (NodePort 30800) over Tailscale HTTPS :10000";
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
      ExecStop = "${tailscale}/bin/tailscale serve --https=10000 off";
    };
  };
}
