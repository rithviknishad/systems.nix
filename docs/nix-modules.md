---
title: NixOS & modules
layout: default
nav_order: 3
---

# NixOS & modules

This page walks the NixOS side of the repo top to bottom: the flake, the host
entry point, and every module under `modules/`.

## The flake (`flake.nix`)

### Inputs

| Input | Purpose |
|---|---|
| `nixpkgs` | `nixos-unstable` — the package set and NixOS modules |
| `disko` | declarative disk partitioning / ZFS layout |
| `sops-nix` | encrypted secrets, decrypted at activation |
| `home-manager` | per-user environment, as a NixOS module |
| `nixos-anywhere` | remote bare-metal installer (used via `nix run`) |

Every secondary input `follows` `nixpkgs`, so the whole tree resolves against a
single nixpkgs revision (fewer duplicate dependencies, faster evaluation).

### Outputs

| Output | What it is |
|---|---|
| `nixosConfigurations.avocado` | the full system (`x86_64-linux`), built for deploy/install |
| `homeConfigurations."rithviknishad@avocado"` | standalone Home Manager profile for `nh home switch` |
| `devShells.default` | the tool shell (`nix develop`) for all four common systems |
| `formatter` | `nixfmt` (`nix fmt`) |

The dev shell puts `just`, `nixos-rebuild`, `sops`, `age`, `ssh-to-age`,
`mkpasswd`, `nixfmt`, `git`, `cloudflared`, `kubectl`, `kubernetes-helm`,
`helmfile`, and `nixos-anywhere` on `PATH`, and defaults `SOPS_AGE_KEY_FILE`
to `~/.config/sops/age/keys.txt`. Enter it with `nix develop` or let `direnv`
load it automatically via `.envrc`.

## Host entry point (`hosts/avocado/`)

### `default.nix`

The host file is deliberately thin: it sets the hostname, enables
NetworkManager, pins `system.stateVersion = "26.11"`, and **imports every
module**. Adding a capability to the box means adding one line here plus a
module file.

```nix
imports = [
  ./hardware.nix ./disko.nix
  ../../modules/base.nix ../../modules/ssh.nix ../../modules/nh.nix
  ../../modules/sops.nix ../../modules/zfs.nix ../../modules/desktop.nix
  ../../modules/home-manager.nix ../../modules/tailscale.nix
  ../../modules/k3s.nix ../../modules/monitoring.nix
  ../../modules/cloudflared.nix ../../users/rithviknishad.nix
];
```

> `system.stateVersion` governs stateful defaults chosen at install time. Do
> **not** bump it casually after install.

### `hardware.nix`

Boot and kernel specifics for this exact machine:

- initrd modules for the SATA/USB controllers (`ahci`, `xhci_pci`, `sd_mod`, …).
- `kvm-intel` for virtualization.
- **systemd-boot** on UEFI, ESP at `/boot`, keep the last 10 generations.
- ZFS support enabled with `networking.hostId = "b288d857"` (ZFS requires a
  unique 8-hex host id for pool ownership).
- Intel microcode updates + redistributable firmware.
- `ondemand` CPU governor.

Filesystems are **not** declared here — [disko](storage.md) owns them.

## The modules

Each module is small, commented, and does one job. Here's what every one adds.

### `base.nix` — shared system baseline

- Enables **flakes** and the modern `nix` CLI; `trusted-users = root, @wheel`.
- **Automatic GC** weekly, deleting generations older than 30 days;
  `auto-optimise-store` on.
- Timezone `Asia/Kolkata`, locale `en_US.UTF-8`, `allowUnfree = true`.
- A small system package set: `git vim curl wget htop tmux rsync`.
- **Firewall on** (individual ports are opened by the modules that need them).

### `ssh.nix` — OpenSSH server

Key-only login (`PasswordAuthentication = false`), root allowed only with a key
(`prohibit-password`), firewall opened automatically. This is what
`nixos-anywhere` and every `nixos-rebuild --target-host` rely on.

### `nh.nix` — the "nix helper" workflow

Symlinks `/etc/nixos` → the in-home clone at `/home/rithviknishad/systems.nix`
and points `nh` at it, so on the box you can run:

```sh
nh os switch   # build + activate
nh os boot     # stage for next boot
nh os build    # build only, no sudo
```

### `sops.nix` — secrets wiring

Imports the sops-nix module, sets `secrets/avocado.yaml` as the default source,
and reads the host age key from `/var/lib/sops-nix/key.txt`. Declares the two
secrets needed early at activation: the user's `hashed-password`
(`neededForUsers`) and the user's SSH private key. Full model on the
[Secrets](secrets.md) page.

### `zfs.nix` — pool maintenance

- Weekly **scrub** and periodic **trim**.
- `services.zfs.autoSnapshot` is enabled with a retention ladder
  (frequent/hourly/daily/weekly/monthly).

> **Heads-up:** auto-snapshot only acts on datasets tagged
> `com.sun:auto-snapshot=true`. The pool root sets it to `false`
> ([disko.nix](storage.md)) and no dataset overrides it, so **no automatic
> snapshots are taken today**. To start snapshotting `/home`, set that property
> on the `home` dataset. Scrub and trim run regardless.

### `desktop.nix` — GNOME workstation

- GNOME on **Wayland** via **GDM**; PipeWire audio (ALSA + Pulse shims),
  `rtkit` for realtime scheduling.
- **Never sleeps:** the `sleep`, `suspend`, `hibernate`, and `hybrid-sleep`
  systemd targets are masked, and GDM auto-suspend is off — critical because
  idle suspend once dropped the box off the network. GNOME's per-user idle
  actions are additionally disabled in [Home Manager](home-manager.md).
- Trims unwanted GNOME apps (`gnome-tour`, `epiphany`, `geary`), adds
  `gnome-tweaks`, and installs Noto/DejaVu fonts.

### `home-manager.nix` — Home Manager as a NixOS module

Imports the home-manager NixOS module, uses global pkgs / user packages, backs
up clobbered dotfiles with a `.hm-bak` suffix, and mounts the
`home/rithviknishad` profile for the user. See [Home Manager](home-manager.md).

### `tailscale.nix` — private mesh networking

Declarative Tailscale: auto-authenticates from a sops-managed auth key,
`useRoutingFeatures = "both"`, trusts the `tailscale0` interface in the
firewall, and sets reverse-path filtering to `loose`. See
[Networking](networking.md).

### `k3s.nix` — single-node Kubernetes

k3s as a **server** with `clusterInit = true` (embedded etcd, so more
servers/agents can join later for HA). Token from sops; API cert issued for the
tailnet name via `--tls-san`. Bundled Traefik / local-path / ServiceLB left on.
Opens `6443` (API), `2379`/`2380` (etcd), `10250` (kubelet), and UDP `8472`
(flannel VXLAN). Installs `kubectl`, `helm`, and `k9s` on the box. Details on
the [Kubernetes](kubernetes.md) page.

### `cloudflared.nix` — Cloudflare Tunnel

Runs a named tunnel that maps public subdomains of `rithviknishad.dev`
(`hello`, `photos`, `grafana`, `status`) to `http://localhost:80` (Traefik),
with a default `http_status:404`. Credentials come from a sops binary secret.
See [Networking](networking.md).

### `monitoring.nix` — host-side metrics glue

The in-cluster monitoring stack can't read per-pool ZFS health or SMART from
inside a pod, so this module runs two **systemd timers** that write Prometheus
*textfile* metrics to `/var/lib/node-exporter/textfile`, which node-exporter
mounts read-only:

| Timer | Cadence | Emits | Feeds |
|---|---|---|---|
| `zfs-textfile-metrics` | every 1 min | `node_zfs_zpool_state` | ZFS pool-health alerts |
| `smart-textfile-metrics` | every 5 min | `smartmon_*` (health, temp, power-on hours) | SMART disk alerts |

Both scripts write to a temp file, `chmod 0644` (node-exporter runs unprivileged
and needs world-readable files), then **atomically `mv`** into place so the
collector never reads a partial file. The SMART script probes several
`smartctl -d` access types to handle SATA drives behind the AHCI controller.
This is the host half of the [Monitoring](monitoring.md) stack.

## The system user (`users/rithviknishad.nix`)

- `users.mutableUsers = false` — accounts are fully declarative; no
  `passwd`-ing on the box.
- User `rithviknishad`: groups `wheel` (sudo), `networkmanager`, `dialout`;
  login shell **zsh**; **password hash comes from sops**
  (`hashedPasswordFile`).
- Authorized SSH keys for the user *and* for `root` (root keys let
  `nixos-anywhere` connect during install). Two keys are trusted: the owner's
  and a collaborator's (`tellmeY18`).
