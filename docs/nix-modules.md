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
| `nixosConfigurations.g8way` / `.headless` | k3s agents (`hosts/g8way/`, `hosts/headless/`), joined 2026-11-04, see [Cluster nodes](nodes.md) |
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
  ../../modules/sops.nix ../../modules/zfs.nix
  ../../modules/avahi.nix ../../modules/iperf.nix
  ../../modules/kiosk.nix ../../modules/home-manager.nix
  ../../modules/tailscale.nix ../../modules/k3s.nix
  ../../modules/monitoring.nix ../../modules/cloudflared.nix
  ../../modules/docker.nix ../../modules/care-box.nix
  ../../modules/zerodha-kite.nix ../../modules/settle-up-mcp.nix
  ../../users/rithviknishad.nix
];
```

> `system.stateVersion` governs stateful defaults chosen at install time. Do
> **not** bump it casually after install.

`hosts/g8way/` and `hosts/headless/` follow the same shape (`default.nix`,
`hardware.nix`, `disko.nix`) but start from a minimal set: `base`, `ssh`,
`zfs`, `avahi` and the user. Both have since added `sops` and `tailscale`.
g8way also imports [`desktop-cinnamon`](#desktop-cinnamonnix--cinnamon-desktop),
[`jumpbox`](#jumpboxnix--cluster-tools--kubeconfig),
[`home-manager`](#home-managernix--home-manager-as-a-nixos-module) and
[`nh`](#nhnix--the-nix-helper-workflow), and its `hardware.nix` sets up Intel
VA-API (iHD) for the HD 5500. Both also import
[`k3s-agent`](#k3snix--k3s-agentnix--k3s-commonnix--kubernetes) and joined
the cluster on 2026-11-04. See [Cluster nodes](nodes.md).

avocado's `default.nix` also sets `sops.age.keyFile` (its dedicated age key,
see [`sops.nix`](#sopsnix--secrets-wiring)); the other hosts don't need to.

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
- A small system package set: `git vim curl wget htop tmux rsync nmap`.
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

Imported by avocado and g8way. The clone itself is a one-time manual step
(done on both). Without it, `/etc/nixos` dangles and `nh os` just errors.
On g8way, `nh` builds whatever was last pulled into its clone, so `git pull`
first. Day-2 deploys to g8way usually still go from avocado (see
[Deployment](deployment.md#deploying-to-g8way-and-headless)).

### `sops.nix` — secrets wiring

Imports the sops-nix module and is **host-agnostic**: the default source is
`secrets/<hostname>.yaml`. How the host decrypts is a per-host choice:

- **avocado** uses a dedicated age key at `/var/lib/sops-nix/key.txt`, set in
  `hosts/avocado/default.nix` (`sops.age.keyFile`, `generateKey = false`).
- **Other hosts** use the sops-nix default, an age identity derived from the
  SSH host key, so there's nothing to provision after install.

The module declares only the user's `hashed-password` (`neededForUsers`) and
**wires it into the user** (`users.users.rithviknishad.hashedPasswordFile`).
A host that doesn't import `sops.nix` yet (a fresh g8way) gets an
SSH-key-only account instead of a broken reference to a missing secret.
Secrets with a single consumer are declared next to it (e.g. the user's SSH
key in [`home-manager.nix`](#home-managernix--home-manager-as-a-nixos-module)).
Full model on the [Secrets](secrets.md) page.

### `zfs.nix` — pool maintenance

- Weekly **scrub** and periodic **trim**.
- `services.zfs.autoSnapshot` is enabled with a retention ladder
  (frequent/hourly/daily/weekly/monthly).

> **Heads-up:** auto-snapshot only acts on datasets tagged
> `com.sun:auto-snapshot=true`. The pool root sets it to `false`
> ([disko.nix](storage.md)) and no dataset overrides it, so **no automatic
> snapshots are taken today**. To start snapshotting `/home`, set that property
> on the `home` dataset. Scrub and trim run regardless.

### `avahi.nix` — mDNS (`<hostname>.local`)

Runs **Avahi** so each host answers multicast queries for **`<hostname>.local`**
(`avocado.local`, `g8way.local`, `headless.local`) on the LAN. Before this, the box had no LAN-resolvable name at all — `avocado` is
a Tailscale MagicDNS name that only works inside the tailnet, and the LAN has
no DNS record for it.

- `publish.addresses` — publishes this host's A/AAAA records only (no
  `workstation`/`userServices` chatter).
- `allowInterfaces` — LAN NIC only, set **per host** in
  `hosts/<host>/default.nix` because NIC names differ (avocado `enp2s0`,
  g8way `enp0s25`, headless `enp1s0`). Multicast never crosses Tailscale, and
  publishing on `cni0`/`flannel.1`/`docker0` would advertise unreachable
  `10.42.x`/`172.17.x` addresses.
- `openFirewall` — UDP 5353.
- `nssmdns4` — lets the box resolve *other* `*.local` names too.

{: .note }
> **Host name only.** mDNS has no notion of subdomains, so this does **not**
> make the `*.avocado.local` Traefik ingress hosts (`grafana.avocado.local`, …)
> resolve — those still need LAN DNS or `/etc/hosts`. See
> [Networking](networking.md#mdns-avocadolocal).

### `iperf.nix` — throughput testing

Installs the `iperf3` CLI and runs an **always-on iperf3 server** (systemd
unit, `DynamicUser`), so any LAN or tailnet machine can run
`iperf3 -c avocado.local` without SSH-ing in to start `iperf3 -s` first.
`openFirewall` opens **TCP 5201**; the module additionally opens **UDP 5201**
by hand, because the upstream option covers TCP only and `iperf3 -u` carries
its data over UDP.

### `kiosk.nix` — stats display (cage + btop)

- The built-in screen is a **kiosk**: [cage](https://github.com/cage-kiosk/cage)
  (a single-application Wayland compositor) starts at boot on tty1 and runs
  **btop** fullscreen inside a `foot` terminal. No desktop, no login screen,
  no screensaver — nothing to lock or idle. (This replaced the earlier GNOME
  desktop module.)
- The session runs as a dedicated **`kiosk` user** with no password, no SSH
  keys, and no sudo; the console exposes only btop. Admin access stays SSH
  (key-only). VT switching is left enabled (`-s`) so a getty on tty2 remains
  reachable with physical access if the network dies.
- **Never sleeps:** the `sleep`, `suspend`, `hibernate`, and `hybrid-sleep`
  systemd targets are masked — critical because idle suspend once dropped the
  box off the network.
- Enables graphics (Intel UHD 620), installs DejaVu for foot, and adds `btop`
  + foot's terminfo system-wide.

### `desktop-cinnamon.nix` — Cinnamon desktop

The g8way desktop, written host-agnostic. Cinnamon on **LightDM** (slick
greeter, Mint themes) under X11. Cinnamon and LightDM options still live under
`services.xserver.*` in current nixpkgs; `defaultSession` and PulseAudio have
moved to `services.*`. The upstream Cinnamon module already brings blueman,
polkit, gnome-keyring, gvfs/udisks, NetworkManager and its own network applet.
This module adds or pins:

- **PipeWire** with the PulseAudio + ALSA shims, rtkit, PulseAudio off.
- **Bluetooth** + blueman, set explicitly instead of relying on Cinnamon's
  `mkDefault`.
- **No `programs.nm-applet`**: Cinnamon's applet already drives NM, and a
  second one would just add another tray icon.
- **Printing off** (no printer around; flip it on and Cinnamon adds
  `system-config-printer`).
- Fonts: Liberation + Noto Color Emoji on top of Cinnamon's DejaVu/Ubuntu.
  The full Noto/CJK sets are skipped because g8way's closure goes over a slow
  link.
- **No autologin**, because the session holds cluster-admin and SSH
  credentials.

Host-specific bits stay in the host: Intel VA-API in
`hosts/g8way/hardware.nix`, and masking the sleep targets (a k3s node must
never idle-suspend) in `hosts/g8way/default.nix`.

### `jumpbox.nix` — cluster tools + kubeconfig

Turns a host into a jumpbox for avocado's cluster:

- Tools: `kubectl`, `kubectx`/`kubens`, `k9s`, `stern`, `helm`, `helmfile`,
  `sops`, `age`, `ssh-to-age`, `dig`, `mtr`, `tcpdump`, `btop`, `jq`, `yq`,
  `just` (plus `git`/`nmap`/`htop` from `base.nix`).
- The **admin kubeconfig** as sops secret `kubeconfig` from the host's own
  `secrets/<hostname>.yaml` (`server: https://avocado:6443` over the tailnet),
  decrypted to `/run/secrets/kubeconfig` (user-owned, `0400`) and exported
  as **`KUBECONFIG`** via `environment.sessionVariables`. That covers SSH,
  TTY and the desktop session. It's not symlinked to `~/.kube/config` because
  sops-nix would create `~/.kube` as root and break kubectl's cache dir.
  Because the file is read-only, `kubectl config use-context`-style writes
  fail by design.
- Not for avocado, where `k3s.nix` already provides the tools and its own
  kubeconfig.

### `home-manager.nix` — Home Manager as a NixOS module

Imports the home-manager NixOS module, uses global pkgs / user packages, backs
up clobbered dotfiles with a `.hm-bak` suffix, and mounts the
`home/rithviknishad` profile for the user. It also declares the
`rithviknishad/ssh_id_ed25519` sops secret (binary file
`secrets/ssh_id_ed25519`, owned by the user, mode `0600`), since the profile
is its only consumer. Imported by avocado and g8way, so both are recipients of
that file. On g8way that's a deliberate security tradeoff, see
[Secrets](secrets.md#how-the-box-consumes-secrets). Every app in the profile
is host-agnostic. The GUI ones (Firefox, kitty, Zed, Lens) only matter on
g8way's desktop, since avocado has no desktop. See
[Home Manager](home-manager.md).

### `tailscale.nix` — private mesh networking

Declarative Tailscale: auto-authenticates from `tailscale/auth-key` in the
host's `secrets/<hostname>.yaml`. Prefer a **tagged, reusable** key, so the
node key never expires; without a valid key the autoconnect unit fails
harmlessly. Also sets `useRoutingFeatures = "both"`, trusts the `tailscale0` interface in the
firewall, and sets reverse-path filtering to `loose`. See
[Networking](networking.md).

### `k3s.nix` / `k3s-agent.nix` / `k3s-common.nix` — Kubernetes

- **`k3s.nix`** (avocado): k3s as the **server**, with `clusterInit = true`
  (embedded etcd). API cert issued for the tailnet name via `--tls-san`.
  Bundled Traefik / local-path / ServiceLB left on. Opens `6443` (API),
  `2379`/`2380` (etcd), `10250` (kubelet), and UDP `8472` (flannel VXLAN).
  Installs `kubectl`, `helm`, and `k9s` on the box.
- **`k3s-agent.nix`** (g8way, headless): k3s as an **agent** joining
  `https://avocado:6443`, registered with the taint
  `rithviknishad.dev/opt-in=true:NoSchedule`, so workloads only land there
  by opting in.
- **`k3s-common.nix`** (imported by both): the `k3s/token` sops secret, and
  cluster traffic over the **tailnet**: `--flannel-iface=tailscale0`, plus
  an `ExecStartPre` that waits for `tailscale0`'s IPv4 and writes it as
  `node-ip` to `/run/k3s/node-ip.yaml` (`--config`). It's written at
  start-up rather than hardcoded so a reinstall's new Tailscale IP just works,
  and IPv4 only because interface auto-detection would also pick up
  `tailscale0`'s IPv6.

Details on the [Kubernetes](kubernetes.md) and [Cluster nodes](nodes.md#phase-3-join-k3s-over-the-tailnet)
pages.

### `cloudflared.nix` — Cloudflare Tunnel

Runs a named tunnel that maps public subdomains of `rithviknishad.dev`
(`hello`, `photos`, `grafana`, `status`, `apps`, …) to `http://localhost:80`
(Traefik), with a default `http_status:404`. Credentials come from a sops
binary secret. See [Networking](networking.md).

### `docker.nix` — local image builds

Docker as a **build tool only** — some k8s workloads need images upstream
doesn't publish in a usable form (the [care](care.md) backend bakes plugins
in at image build time; care_fe compiles the API URL into the bundle). The
`care-images` justfile recipes `docker build` them on the box and import the
result straight into k3s's containerd (`k3s ctr images import`) — no registry,
same idea as the Nix-built [zerodha-kite](zerodha-kite.md) image. Weekly `autoPrune` keeps build-cache
layers from eating the pool. Nothing runs under docker; workloads live in k3s.

### `care-box.nix` — control plane for the Pi

avocado's side of [CARE in a box](care-box.md), which runs on the Raspberry
Pi **lumine** (Raspberry Pi OS, configured from `lumine/` by the `box-*`
recipes). It pins lumine's SSH host key in the system-wide `known_hosts`
(under `lumine`, its tailnet FQDN, `lumine.local` and its tailnet IP), so
neither a recipe run nor a root service trusts it on first use.

It also **pulls nightly backups** of care-box: `care-box-backup.service`
(timer ~03:15, as the unprivileged `care-box-backup` user, sandboxed) runs
`pg_dump` and rsyncs the uploads from lumine, using an SSH key from sops
(`secrets/care-box-backup_ed25519`) that the Pi locks to a forced command.
It keeps 7 days in `/var/lib/care-box-backups` and writes `care_box_backup_*`
textfile metrics for the backup alerts. See
[CARE in a box → Backups](care-box.md#backups).

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
  login shell **zsh**. The **password hash comes from sops**, but
  `hashedPasswordFile` is set in `modules/sops.nix`, not here, so hosts can
  import the user before they have a sops key. Until then the account has no
  password (SSH key only) and admin work goes through root's key.
- Authorized SSH keys for the user *and* for `root` (root keys let
  `nixos-anywhere` connect during install). Two keys are trusted: the owner's
  and a collaborator's (`tellmeY18`).
