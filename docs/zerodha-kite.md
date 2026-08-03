---
title: Zerodha Kite (MCP server)
layout: default
nav_order: 18
---

# Zerodha Kite MCP server

[`zerodha/kite-mcp-server`](https://github.com/zerodha/kite-mcp-server) is a
[Model Context Protocol](https://modelcontextprotocol.io) server that gives AI
clients (Claude Desktop, VS Code, Cursor, ...) access to the **Kite Connect
trading API** — market data, holdings, positions, orders, and GTTs. It runs on
the k3s cluster under `k8s/zerodha-kite/`.

{: .note }
> **Why "zerodha-kite" and not "kite"?** The repo already runs the
> [Kite Kubernetes dashboard](kite.md) (`kite-org/kite`, `k8s/kite`). To avoid a
> name clash across the flake, image, namespace, `just` recipes, and the MCP
> client config, this trading server is namespaced `zerodha-kite` everywhere.

{: .warning }
> This instance runs the **full tool set with no exclusions** — it can place,
> modify, and cancel **real orders and GTTs** on your live Zerodha account. It
> is deliberately reachable over the **tailnet only** (see exposure below).
> Anyone who can reach `avocado:30080` and complete a Kite login can trade as
> you.

## Architecture

The server is built by Nix from a pinned source and preloaded into k3s — the
same no-registry pattern as [Bingo](kubernetes.md#bingo-multiplayer-game--k8sbingo).

```mermaid
graph TD
    input[flake input: kite-mcp-server pinned] --> pkg[pkgs/zerodha-kite<br/>buildGoModule + dockerTools]
    pkg --> img[OCI image zerodha-kite:latest]
    img -->|services.k3s.images<br/>modules/zerodha-kite.nix| ctr[(containerd)]
    ctr --> pod[zerodha-kite pod :8080<br/>APP_MODE=hybrid]
    npc[NodePort Service :30080] --> pod
    ts[Tailscale client<br/>MagicDNS 'avocado'] -->|avocado:30080| npc
```

- **Image**: `buildGoModule` compiles the Go binary; `dockerTools.buildLayeredImage`
  wraps it with CA certificates (HTTPS to `api.kite.trade`) and `tzdata` +
  `TZ=Asia/Kolkata` (Kite quotes/candles are IST). See
  `pkgs/zerodha-kite/default.nix`.
- **Preload**: `modules/zerodha-kite.nix` adds the image tarball to
  `services.k3s.images`; `just deploy` restarts k3s so it is imported into
  containerd before the pod starts. The pod uses `imagePullPolicy: IfNotPresent`
  — there is no registry.
- **Mode**: `APP_MODE=hybrid` serves **both** `/mcp` (streamable HTTP) and
  `/sse` (SSE) on port 8080, so any client's preferred transport works.

## Exposure — tailnet only, via NodePort

Unlike the other cluster services (Traefik ingress on `*.avocado.local` /
public Cloudflare hosts), this server is exposed with a fixed **NodePort**
(`30080`), reachable at **`http://avocado:30080`** over Tailscale MagicDNS.

Why a NodePort instead of an ingress:

- The Kite auth flow is **browser-based**. The `login` MCP tool returns
  `http://avocado:30080/authorize`; after you log in to Kite, your browser is
  redirected to `http://avocado:30080/callback?request_token=...`. Both the MCP
  transport and the browser must hit the **same real `host:port`** — a
  Host-header `*.avocado.local` route can't be followed by a browser OAuth
  redirect.
- `tailscale0` is a trusted firewall interface (`modules/tailscale.nix`), but
  the NodePort range is **not** in the host's `allowedTCPPorts`
  (`modules/k3s.nix`). So `avocado:30080` is reachable **over the tailnet** and
  blocked on the WAN/LAN. No public route, no Cloudflare Access gate.

`PUBLIC_BASE_URL` (in `k8s/zerodha-kite/zerodha-kite.yaml`), the NodePort, and
the Kite Connect app's **Redirect URL** must all agree on
`http://avocado:30080`.

## One-time setup: create a Kite Connect app

You need your own Kite Connect API credentials (the hosted `mcp.kite.trade`
would work too, but self-hosting is the point here):

1. Sign up / log in at [developers.kite.trade](https://developers.kite.trade)
   and **create a new app** (Kite Connect). This has a one-time fee on
   Zerodha's side.
2. Set the app's **Redirect URL** to exactly:

   ```
   http://avocado:30080/callback
   ```

3. Copy the **API key** and **API secret** into the sops secret:

   ```sh
   just zerodha-kite-secrets      # opens secrets/zerodha-kite.enc.yaml in sops
   # set KITE_API_KEY and KITE_API_SECRET, save & quit
   ```

## Deploy

```sh
# 1. Preload the Nix-built image into k3s (also builds it). Confirm before this
#    — it activates on the live box.
just deploy

# 2. Apply the manifests + the sops secret, and roll the pod.
just zerodha-kite-deploy

# Watch / debug
just zerodha-kite-status
just zerodha-kite-logs
```

`just deploy` is what puts `zerodha-kite:latest` into containerd (via
`services.k3s.images`); `just zerodha-kite-deploy` only applies the k8s
manifests and secret.

## Connecting a client

Any machine that is **on your tailnet** and resolves `avocado` via MagicDNS can
connect. The bridge is [`mcp-remote`](https://www.npmjs.com/package/mcp-remote)
(run through `npx`), which lets stdio-only clients talk to the HTTP/SSE
endpoint. `--allow-http` is required because the endpoint is plain HTTP on the
tailnet (the tailnet itself is the encrypted transport).

### Claude Desktop

Edit `claude_desktop_config.json` (macOS:
`~/Library/Application Support/Claude/`, Linux: `~/.config/Claude/`):

```json
{
  "mcpServers": {
    "zerodha-kite": {
      "command": "npx",
      "args": ["mcp-remote", "http://avocado:30080/mcp", "--allow-http"]
    }
  }
}
```

Restart Claude Desktop. To use the SSE transport instead, swap `/mcp` for
`/sse`.

### VS Code / Cursor / other MCP clients

VS Code (`.vscode/mcp.json` in a workspace, or the global MCP settings):

```json
{
  "servers": {
    "zerodha-kite": {
      "command": "npx",
      "args": ["mcp-remote", "http://avocado:30080/mcp", "--allow-http"]
    }
  }
}
```

Clients that speak streamable HTTP natively can instead point straight at the
URL `http://avocado:30080/mcp` with no `mcp-remote` wrapper.

### Logging in (per client, each session)

1. Ask the assistant to run the **`login`** tool. It replies with an
   `http://avocado:30080/authorize?...` link.
2. Open that link **in a browser on a tailnet machine**. It bounces you to the
   Kite login; sign in and authorize.
3. Kite redirects to `http://avocado:30080/callback` and the session is bound to
   your MCP client. Now the portfolio/market/order tools work.

Sessions are per MCP client and **expire** — re-run `login` when tools start
returning "session not found".

{: .note }
> **Not on the tailnet?** Add the client machine to your Tailscale network
> (`tailscale up`) so it resolves `avocado` and can reach `:30080`. There is no
> LAN or public fallback by design. If you truly need LAN access, you would
> have to open the NodePort in `modules/k3s.nix` — don't, unless you understand
> the exposure.

## Updating the server

```sh
just update kite-mcp-server        # bump the pinned input (confirm-first)
# If go.sum changed, the build fails with the correct vendorHash — paste it
# into pkgs/zerodha-kite/default.nix (vendorHash).
just eval                          # sanity check
just deploy                        # re-preload the new image (confirm-first)
just zerodha-kite-deploy           # roll the pod onto :latest
```

## Monitoring

Gatus probes the in-cluster Service status page
(`http://zerodha-kite.zerodha-kite.svc:8080/`, group `internal`) every minute
and alerts on the `avocado-alerts` ntfy topic if it stops returning `200`. This
proves the server is up; it does **not** track whether any Kite login session
is active (those are per-client and transient). See [Monitoring](monitoring.md).

## Files

| Path | Purpose |
|---|---|
| `flake.nix` | `kite-mcp-server` input + `zerodha-kite-app` / `zerodha-kite-image` packages |
| `pkgs/zerodha-kite/default.nix` | `buildGoModule` binary + `dockerTools` OCI image |
| `modules/zerodha-kite.nix` | preload the image into k3s (`services.k3s.images`) |
| `k8s/zerodha-kite/` | namespace, ConfigMap, Deployment, NodePort Service |
| `secrets/zerodha-kite.enc.yaml` | sops-encrypted `KITE_API_KEY` + `KITE_API_SECRET` |
| `justfile` | `zerodha-kite-deploy` / `-status` / `-logs` / `-secrets` recipes |
