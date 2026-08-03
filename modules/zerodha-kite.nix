#
# zerodha-kite — preload the Nix-built Kite MCP server image into k3s.
#
# The k8s/zerodha-kite workload runs `zerodha-kite:latest` with
# imagePullPolicy: IfNotPresent and no registry behind it. This makes that
# image available: services.k3s.images links the OCI tarball into k3s's
# imageDir, and the k3s agent imports it into containerd before workloads
# start. Same no-registry pattern as modules/bingo.nix.
#
# Updating the server: `just update kite-mcp-server` (+ recompute vendorHash in
# pkgs/zerodha-kite/default.nix if go.sum changed), then `just deploy` —
# activation restarts k3s so the new tarball is re-imported — followed by
# `just zerodha-kite-deploy` (which ends in a rollout restart) to pull the
# refreshed :latest into a new pod.
{ inputs, pkgs, ... }:
{
  services.k3s.images = [
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.zerodha-kite-image
  ];
}
