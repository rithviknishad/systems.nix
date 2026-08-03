# zerodha/kite-mcp-server — a Go MCP (Model Context Protocol) server exposing
# the Kite Connect trading API to AI clients (Claude Desktop, VS Code, ...).
#
# This derivation builds the Go binary (`buildGoModule`) and packages it into a
# slim OCI image (`.image`) that k3s preloads via services.k3s.images (see
# modules/zerodha-kite.nix) — no registry, same pattern as pkgs/bingo.
#
# WHY it is called "zerodha-kite" and not "kite": the repo already runs the Kite
# *Kubernetes dashboard* (k8s/kite, kite-org/kite). To avoid a name clash across
# the flake, package, image, namespace, and MCP-client config, this trading
# server is namespaced "zerodha-kite" everywhere.
#
# Runtime needs baked into the image:
#   - CA certificates: the server talks to api.kite.trade over HTTPS (login,
#     order placement, instruments dump). Without cacert every call fails x509.
#   - tzdata + TZ=Asia/Kolkata: Kite quotes/historical candles are IST; a
#     scratch image has no zoneinfo, so time parsing would fall back to UTC.
{
  lib,
  buildGoModule,
  dockerTools,
  cacert,
  tzdata,
  src,
  version,
}:
let
  app = buildGoModule {
    pname = "kite-mcp-server";
    inherit version src;

    # Vendor hash of the Go module dependencies. Recompute (build once with
    # lib.fakeHash, paste the "got:" hash) when the pinned `kite-mcp-server`
    # input (and thus go.sum) changes.
    vendorHash = "sha256-ClJ1qIcdtvg0UTmRCoww4kzxDMIBuqftdKSM83ZrdE8=";

    # Match the upstream justfile: inject the version into main, strip symbols.
    ldflags = [
      "-s"
      "-w"
      "-X main.MCP_SERVER_VERSION=${version}"
    ];

    # Upstream's timing tests need GOEXPERIMENT=synctest + network; skip them at
    # build time (we track a pinned upstream, not our own patches).
    doCheck = false;

    meta = {
      description = "MCP server for the Zerodha Kite Connect trading API";
      homepage = "https://github.com/zerodha/kite-mcp-server";
      license = lib.licenses.mit;
      mainProgram = "kite-mcp-server";
    };
  };
in
{
  inherit app;

  image = dockerTools.buildLayeredImage {
    name = "zerodha-kite";
    tag = "latest";
    # cacert + tzdata land in the image so HTTPS to Kite works and IST timestamps
    # parse; see the header note.
    contents = [
      app
      cacert
      tzdata
    ];
    config = {
      Entrypoint = [ "${app}/bin/kite-mcp-server" ];
      Env = [
        "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
        "TZ=Asia/Kolkata"
        "TZDIR=${tzdata}/share/zoneinfo"
      ];
      ExposedPorts."8080/tcp" = { };
    };
  };
}
