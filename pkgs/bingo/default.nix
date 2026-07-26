# sonzsara/bingo-app — a boardgame.io (Koa) multiplayer server that ALSO serves
# the Vite/React SPA. One process, one port (8000): static files + the
# socket.io multiplayer API live at the same origin.
#
# This derivation builds the SPA (`vite build`) and packages it together with
# the server sources and node_modules into a slim OCI image (`.image`) that k3s
# preloads via services.k3s.images (see modules/bingo.nix) — no registry.
#
# WHY serverUrl is baked at build time: the browser client picks its socket.io
# server from VITE_SERVER_URL, falling back to `<host>:8000` (see
# src/lib/constants.js). Port 8000 is NOT one of Cloudflare's proxied ports —
# the tunnel only forwards :443 -> localhost:80 — so without this the
# multiplayer socket would dial bingo.rithviknishad.dev:8000 and never connect.
# Pinning it to the bare https origin keeps client and server same-origin on
# 443, which the tunnel + Traefik route (websockets included) to this pod.
{
  lib,
  buildNpmPackage,
  nodejs,
  dockerTools,
  src,
  version,
  serverUrl ? "https://bingo.rithviknishad.dev",
}:
let
  app = buildNpmPackage {
    pname = "bingo-app";
    inherit version src nodejs;

    # From `nix run nixpkgs#prefetch-npm-deps -- package-lock.json`.
    # Recompute when the pinned `bingo-app` input (and its lockfile) changes.
    npmDepsHash = "sha256-k02FKLXVa9stYGeq8sdSsm+V4ngDQAkhHGzMnfxxPeE=";

    # Vite reads this at build time (import.meta.env.VITE_SERVER_URL).
    env.VITE_SERVER_URL = serverUrl;

    # `npm run build` == `vite build` -> dist/. We don't publish an npm package;
    # instead keep dist + the runtime server sources + node_modules so the image
    # can run `node server.cjs` (which requires boardgame.io/koa and
    # ./src/game/BingoGame.cjs relative to itself).
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist node_modules server.cjs package.json src $out/
      runHook postInstall
    '';
  };
in
{
  inherit app;

  image = dockerTools.buildLayeredImage {
    name = "bingo-app";
    tag = "latest";
    contents = [ app ];
    config = {
      Cmd = [
        "${nodejs}/bin/node"
        "${app}/server.cjs"
      ];
      WorkingDir = "${app}";
      Env = [
        "PORT=8000"
        "NODE_ENV=production"
      ];
      ExposedPorts."8000/tcp" = { };
    };
  };
}
