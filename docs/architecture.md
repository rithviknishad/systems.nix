---
title: Architecture
layout: default
nav_order: 2
---

# Architecture

This page is the end-to-end mental model of `avocado`. Everything else is
detail on one of these layers.

## The layers

`avocado` is a single physical machine wearing several hats at once:

```mermaid
flowchart TB
    subgraph HW[Physical box: avocado - Intel i7-8550U, UEFI]
        subgraph OS[NixOS - built from this flake]
            base[Base system: nix, gc, firewall]
            desk[GNOME desktop + Home Manager]
            net[Tailscale + Cloudflare Tunnel]
            k3s[k3s server - single node]
            mon[Host metrics timers: ZFS + SMART]
        end
        subgraph ZFS[ZFS pool rpool - striped, no redundancy]
            root[root fs at slash]
            nixds[nix store]
            vards[var - logs, k3s state]
            homeds[home - user data]
        end
    end

    OS --- ZFS
    k3s --> workloads[Workloads: Immich, monitoring stack]
```

Each layer is defined by a NixOS module (see [NixOS & modules](nix-modules.md))
and imported by `hosts/avocado/default.nix`.

## How the flake wires together

```mermaid
flowchart LR
    flake[flake.nix]

    flake --> nixos[nixosConfigurations.avocado]
    flake --> home[homeConfigurations.rithviknishad@avocado]
    flake --> shell[devShells.default]

    nixos --> hw[hosts/avocado/hardware.nix]
    nixos --> disko[hosts/avocado/disko.nix]
    nixos --> mods[modules/*.nix]
    nixos --> user[users/rithviknishad.nix]

    mods --> hm[modules/home-manager.nix]
    hm --> homeprofile[home/rithviknishad]
    home --> homeprofile

    shell --> tools[just, sops, age, kubectl, helm, helmfile, nixos-anywhere]
```

Two ways the same Home Manager profile is used:

- **System-wide** via `modules/home-manager.nix` during a full `nixos-rebuild`
  (`nh os switch`).
- **Standalone** via `homeConfigurations."rithviknishad@avocado"` so you can
  iterate on just your dotfiles with `nh home switch` — no full rebuild.

## How a public request reaches a service

This is the single most important flow to understand. There are **no inbound
ports** open to the internet — `cloudflared` dials *out* to Cloudflare and the
tunnel carries traffic back in.

```mermaid
sequenceDiagram
    participant U as User (browser)
    participant CF as Cloudflare edge (TLS)
    participant CD as cloudflared (on avocado)
    participant T as Traefik (k3s ingress :80)
    participant S as Service pod (e.g. Immich)

    U->>CF: https://photos.rithviknishad.dev
    Note over CF: TLS terminates here
    CF->>CD: tunnel (outbound-established)
    CD->>T: http://localhost:80 (Host: photos.rithviknishad.dev)
    T->>S: route by Host header
    S-->>U: response back through the tunnel
```

Key points:

- **TLS terminates at Cloudflare's edge** — no cert-manager needed on the box.
- `cloudflared` forwards *every* mapped hostname to `localhost:80`, where
  **Traefik routes by `Host` header** to the right k8s Ingress.
- The same services are reachable privately over Tailscale by sending the
  `Host` header to `http://avocado` directly (bypassing Cloudflare).

See [Networking](networking.md) for the full routing table.

## Where data lives

```mermaid
flowchart TB
    pool[ZFS pool: rpool]
    pool --> root[slash - OS root]
    pool --> nixds[nix - store]
    pool --> vards[var - logs, k3s state]
    pool --> homeds[home - user data]

    vards --> lp[k3s local-path provisioner]
    lp --> pvcs[PVCs: Immich library/db, VictoriaMetrics, VictoriaLogs]
```

k3s's built-in **local-path** provisioner carves PersistentVolumes out of the
host filesystem (under `/var`), which sits on the ZFS `rpool`. That means
**every PVC ultimately lives on the no-redundancy stripe** — losing either
disk loses it all. This is exactly why the [monitoring](monitoring.md) stack
puts so much weight on ZFS pool health and SMART alerts.

## Secrets flow (build + boot time)

```mermaid
flowchart LR
    admin[Admin Mac - age key] -->|edit + encrypt| repo[(secrets/*.yaml in repo)]
    repo -->|sops-nix at activation| hostkey[avocado host age key]
    hostkey --> runsecrets[run-secrets mounts]
    runsecrets --> svc[Services: user password, tailscale, k3s, cloudflared]
```

Everything sensitive is committed **encrypted**. The box decrypts at activation
using its own age key at `/var/lib/sops-nix/key.txt` (never in the repo). Full
details on the [Secrets](secrets.md) page.

## Design decisions worth knowing

- **One striped ZFS pool, no redundancy.** Chosen for maximum capacity
  (~342 GB) from two mismatched disks. The tradeoff: any single disk failure
  destroys the whole pool including the OS. Off-box `zfs send` backups are the
  safety net.
- **Desktop + server on one box.** The machine never sleeps (sleep targets are
  masked and GNOME idle actions disabled) so services stay reachable.
- **k3s with bundled add-ons on.** Traefik, ServiceLB, and local-path are left
  enabled for an easy first workload rather than swapping in heavier
  alternatives.
- **Push-based public access.** Cloudflare Tunnel avoids the need for a static
  IP, port forwarding, or a public firewall hole.
- **Secrets in-repo, encrypted.** sops-nix keeps the config fully declarative
  without leaking plaintext — even the CI mirror token never appears in the
  clear.
