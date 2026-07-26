#
# Bingo — preload the Nix-built app image into k3s.
#
# The k8s/bingo workload runs `bingo-app:latest` with imagePullPolicy:
# IfNotPresent and no registry behind it. This makes that image available:
# services.k3s.images links the OCI tarball into k3s's imageDir, and the k3s
# agent imports it into containerd before workloads start. The image is built
# from the pinned `bingo-app` flake input via pkgs/bingo.
#
# Updating the app: `just update bingo-app` (+ recompute npmDepsHash if the
# lockfile changed), then `just deploy` — activation restarts k3s so the new
# tarball is re-imported — followed by `kubectl -n bingo rollout restart
# deploy/bingo` to pull the refreshed :latest into a new pod.
{ inputs, pkgs, ... }:
{
  services.k3s.images = [
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.bingo-image
  ];
}
