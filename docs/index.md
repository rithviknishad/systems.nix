---
title: Home
layout: default
nav_order: 1
---

# systems.nix

Declarative configuration for **avocado** — a single Intel NUC-class box that is
a NixOS workstation *and* a k3s server at the same time. Everything here is
reproducible from this repo: the OS, the disks, the desktop, the user
environment, the Kubernetes workloads, and the monitoring stack.

> One box, defined entirely in code. Reinstall it from bare metal with a single
> `nixos-anywhere` run, then manage it day-to-day with `just`.

## The one-paragraph summary

`avocado` runs **NixOS (unstable)** on a **ZFS root** laid out by
[disko](https://github.com/nix-community/disko) and installed remotely with
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere). A **GNOME**
desktop and a per-user **Home Manager** profile turn it into a usable
workstation. It also runs a single-node **k3s** cluster hosting real workloads
(Immich photos) behind the bundled **Traefik** ingress. The box is reachable
privately over **Tailscale** and publicly through a **Cloudflare Tunnel** (no
open ports). A **VictoriaMetrics + Grafana + ntfy** stack watches the host,
the disks (ZFS + SMART), and the cluster. All secrets are encrypted in-repo
with **sops-nix**.

## Documentation map

| Page | What it covers |
|---|---|
| [Architecture](architecture.md) | End-to-end picture, request flow, and diagrams |
| [NixOS & modules](nix-modules.md) | The flake, every `modules/*.nix`, host and user config |
| [Home Manager](home-manager.md) | The desktop and per-app user environment |
| [Storage: disko & ZFS](storage.md) | Disk partitioning, the `rpool` stripe, snapshots |
| [Secrets: sops-nix](secrets.md) | Encryption model, keys, and the GitHub mirror pipeline |
| [Networking](networking.md) | Tailscale, Cloudflare Tunnel, firewall, ingress routing |
| [Kubernetes (k3s)](kubernetes.md) | The cluster, Immich, and the sample workload |
| [Monitoring](monitoring.md) | VictoriaMetrics, Grafana, alerts, logs, uptime |
| [Deployment & operations](deployment.md) | Install, day-2 workflow, full `just` reference |

## Repository layout

```
flake.nix                     inputs + outputs (nixosConfig, homeConfig, devShell)
justfile                      task runner (deploy, secrets, monitoring, ...)
.sops.yaml                    sops recipients + per-file encryption rules

hosts/avocado/
  default.nix                 host entry point — imports all modules
  hardware.nix                boot/kernel/ZFS hostId/microcode
  disko.nix                   ZFS partition + pool/dataset layout

modules/                      reusable NixOS modules (see NixOS & modules page)
users/rithviknishad.nix       system user + authorized SSH keys
home/rithviknishad/           Home Manager profile + per-app modules

k8s/
  sample.yaml                 hello-world smoke test
  immich/                     self-hosted photos (kustomize)
  monitoring/                 VictoriaMetrics stack (helmfile + kustomize)

secrets/                      sops-encrypted secrets (see Secrets page)
.tangled/workflows/           CI: mirror Tangled -> GitHub
```

## Fast facts

| | |
|---|---|
| Host name | `avocado` |
| Hardware | Intel i7-8550U, UEFI, 2× SATA SSD |
| OS | NixOS `nixos-unstable`, `stateVersion = 26.11` |
| Root filesystem | ZFS pool `rpool` (striped, **no redundancy**) |
| Desktop | GNOME on Wayland (GDM) |
| Orchestrator | k3s server, embedded etcd, Traefik ingress |
| Private access | Tailscale (`avocado` MagicDNS) |
| Public access | Cloudflare Tunnel → `*.rithviknishad.dev` |
| Secrets | sops-nix + age |
| Source of truth | Hosted on Tangled, mirrored to GitHub |

---

New here? Start with the [Architecture](architecture.md) page for the big
picture, then jump to whichever layer you care about.
