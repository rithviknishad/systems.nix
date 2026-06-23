---
name: nixitup
description: Probe an existing Linux box over SSH (CPU, disks by-id, SMART health, network, running services) then scaffold and install a minimal declarative NixOS over it using a flake with disko/ZFS and nixos-anywhere. Produces a lean, bootable base (SSH + flakes + your user) that later config layers (desktop, Home Manager, secrets) build on separately. Use when asked to convert/install a machine to NixOS, provision a new host, or probe a target's hardware for a NixOS config. Handles connecting over a hardcoded IP or a Tailscale name (snapshots tailscale state into a custom kexec image so the box stays reachable during install).
---

# nixitup — probe a box and install minimal NixOS

Convert an existing Linux machine into a minimal, declarative NixOS host. The
output is intentionally **lean**: a bootable system with SSH, flakes, ZFS, and
the user account. Desktop, Home Manager, app modules, and secrets are *layers
added later* — do not bake them in here unless asked.

Work through the phases in order. **Confirm destructive choices with the user
before acting** — disko erases disks.

## Phase 0 — Target & connectivity

Ask the user (or accept from the request) a single `TARGET`. It may be:
- a hostname / `*.local` (mDNS),
- a raw IP address (e.g. `192.168.1.50`),
- a Tailscale MagicDNS name (e.g. `avocado`).

Determine the SSH login and privilege:
- Try `ssh <user>@<TARGET>`. Note if root SSH exists or only sudo is available.
- `nixos-anywhere` kexecs an installer and needs **root** on the target. If only
  sudo exists, either pass `--sudo` or provision a temporary root SSH key first.

If `TARGET` is reached **over Tailscale**, see *Phase 5b* — a plain kexec drops
the tailnet link and the box becomes unreachable mid-install. You must build a
custom kexec image with tailscale state.

## Phase 1 — Probe hardware (read-only)

Save the read-only script below as `probe.sh` and pipe it to the box, or paste
its commands over SSH directly — it only reads:

```sh
ssh <user>@<TARGET> 'bash -s' < probe.sh
```

```bash
#!/usr/bin/env bash
# nixitup hardware/service probe — READ-ONLY. Safe to run on any Linux box.
set -u
sec() { printf '\n===== %s =====\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

sec "HOST"; hostname; uname -a
grep -E '^(NAME|VERSION)=' /etc/os-release 2>/dev/null

sec "CPU"
have lscpu && lscpu | grep -Ei 'model name|vendor|^cpu\(s\)|architecture'
grep -m1 vendor_id /proc/cpuinfo 2>/dev/null

sec "MEMORY"; free -h 2>/dev/null || grep MemTotal /proc/meminfo

sec "FIRMWARE"
[ -d /sys/firmware/efi ] && echo UEFI || echo "BIOS / Legacy"
have bootctl && bootctl status 2>/dev/null | head -n 5

sec "DISKS (lsblk)"
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,MOUNTPOINT 2>/dev/null

sec "DISKS (stable by-id — USE THESE IN disko)"
ls -l /dev/disk/by-id/ 2>/dev/null | grep -vE 'part[0-9]+$' | awk '{print $9, "->", $11}'

sec "SMART HEALTH"
if have smartctl; then
  for d in /dev/sd? /dev/nvme?n1; do
    [ -e "$d" ] || continue
    echo "--- $d ---"
    smartctl -H "$d" 2>/dev/null | grep -Ei 'result|SMART overall'
    smartctl -A "$d" 2>/dev/null | grep -Ei \
      'Reallocated|Pending|Uncorrect|Power_Cycle|Power-Off|Unexpect|Wear|Percentage_Used|Power_On_Hours'
  done
else echo "smartctl missing (apt install smartmontools) — disk health UNKNOWN"; fi

sec "NETWORK INTERFACES (pick the primary NIC name)"
ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$'
ip -4 -o addr show 2>/dev/null | awk '{print $2, $4}'

sec "TAILSCALE"
if have tailscale; then
  tailscale status 2>/dev/null | head -n 5
  echo "state dir:"; ls -la /var/lib/tailscale 2>/dev/null
else echo "tailscale not present"; fi

sec "RUNNING SERVICES"
have systemctl && systemctl list-units --type=service --state=running \
  --no-pager --no-legend 2>/dev/null | awk '{print $1}'

sec "LISTENING SOCKETS"; ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null

sec "DOCKER / PODMAN"
have docker && docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
have podman && podman ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null

sec "USERS (uid >= 1000)"
awk -F: '$3>=1000 && $3<65534 {print $1, $3, $7}' /etc/passwd

sec "AUTHORIZED KEYS"
for h in /root /home/*; do f="$h/.ssh/authorized_keys"; [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; }; done

sec "MOUNTS / FSTAB"
findmnt -t ext4,xfs,btrfs,zfs,vfat -o TARGET,SOURCE,FSTYPE 2>/dev/null
grep -vE '^\s*#' /etc/fstab 2>/dev/null

printf '\n===== PROBE COMPLETE =====\n'
```

Capture from the output:
- **CPU vendor** → `boot.kernelModules = [ "kvm-intel" | "kvm-amd" ]` and the
  matching `hardware.cpu.<intel|amd>.updateMicrocode`.
- **Disks by stable id** — always use `/dev/disk/by-id/...`, never `/dev/sdX`.
- **SMART health** per disk. Flag reallocated/pending sectors and
  unexpected-power-loss counts; warn the user (no UPS = corruption risk).
- **Firmware** — UEFI (`/sys/firmware/efi` present) → systemd-boot; else BIOS/GRUB.
- **Primary NIC name** (e.g. `enp2s0`) → DHCP on that interface.
- Generate a unique 8-hex `networking.hostId` (`head -c4 /dev/urandom | od -An -tx1`).

## Phase 2 — Inventory services (read-only)

`probe.sh` also lists running services, listening sockets, docker containers,
existing users, and authorized_keys. Summarize what is currently running and
produce a short **"to re-create later"** checklist for the user. Do not port
workloads in this phase — keep the first NixOS generation minimal.

## Phase 3 — Decisions (ask; don't assume)

Confirm with the user:
- **Disk topology** (state the trade-off plainly):
  - *stripe* — capacities summed, **no redundancy**, losing either disk loses
    everything. Future growth: add vdevs.
  - *mirror* — capped at the smallest disk, tolerates one disk failure.
    Future: `zpool attach`/`replace`, `autoexpand=on` to grow.
  - *raidz* — for 3+ disks.
- hostname, username, timezone, locale, nixpkgs channel (`nixos-unstable` vs a
  release), `system.stateVersion`.
- SSH **public** key(s) to authorize for the user.

## Phase 4 — Scaffold a minimal flake

Create this lean layout (placeholders `<host>`, `<user>`):

```
flake.nix
hosts/<host>/{default,hardware,disko}.nix
modules/base.nix            # nix flakes, gc, a few CLI tools, firewall
modules/ssh.nix             # OpenSSH, key-only
users/<user>.nix            # user + authorized key + wheel
```

`flake.nix` inputs: `nixpkgs` (chosen channel), `disko` (follows nixpkgs).
`nixosConfigurations.<host>` imports `disko.nixosModules.disko` + `hosts/<host>`.

Keep `modules/base.nix` minimal:
- `nix.settings.experimental-features = [ "nix-command" "flakes" ]`,
  `nix.gc` weekly, `nixpkgs.config.allowUnfree` as needed.
- `environment.systemPackages`: just `git vim curl` (don't over-stuff).
- `networking.firewall.enable = true`.

`hosts/<host>/hardware.nix`: initrd modules from the probe, bootloader
(systemd-boot for UEFI), `boot.supportedFilesystems = [ "zfs" ]`,
`networking.hostId`, CPU microcode, `nixpkgs.hostPlatform`.

`hosts/<host>/disko.nix`: ZFS pool from the chosen topology. Use `by-id` device
paths. One ESP (`1G`, vfat, `/boot`) on the boot disk; remaining space + other
disks as `zfs` partitions joined into the pool. Datasets `root`/`nix`/`var`/`home`
with `mountpoint = "legacy"`, `compression = "zstd"`, `ashift = "12"`,
`autotrim = "on"`. For stripe set pool `mode = ""`; for mirror `mode = "mirror"`.
Do **not** declare `fileSystems` in hardware.nix — disko owns them.

`hosts/<host>/default.nix`: import hardware + disko + the two modules + the user;
set `networking.hostName`, DHCP on the probed NIC, and `system.stateVersion`.

## Phase 5 — Install with nixos-anywhere

When the controller arch differs from the target (e.g. arm64 mac → x86_64),
**always build on the remote**:

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#<host> --build-on remote -L <user-or-root>@<TARGET>
```

Add `--sudo` if logging in as a non-root user. On macOS controllers set
`TMPDIR=/tmp` (a long TMPDIR breaks the SSH ControlPath socket).

### Phase 5b — Installing over Tailscale (stay reachable)

A normal kexec boots a bare installer with no tailscale, so a Tailscale-only
`TARGET` disconnects and the install stalls. Keep the box on the tailnet by
shipping tailscale **and the existing node state** inside a custom kexec image:

1. Snapshot live tailscale state from the target (preserves the node identity so
   it rejoins as the same machine):
   ```sh
   ssh root@<TARGET> 'tar -C /var/lib -czf /tmp/ts-state.tgz tailscale'
   scp root@<TARGET>:/tmp/ts-state.tgz ./ts-state.tgz
   ```
2. Define a kexec installer config in the flake that enables tailscale and
   restores that state on boot, e.g. a `nixosConfigurations.kexec` built from
   `<nixpkgs>/nixos/modules/installer/netboot/netboot-minimal.nix` with
   `services.tailscale.enable = true` and an activation step that untars the
   snapshot into `/var/lib/tailscale` then `tailscale up`. Build its
   `config.system.build.kexecTarball`.
3. Pass it to nixos-anywhere and skip the auto-reboot so you control the kexec:
   ```sh
   nixos-anywhere --flake .#<host> \
     --kexec "$(nix build --print-out-paths .#kexec)" root@<TARGET>
   ```
   Verify exact flags against the current nixos-anywhere docs (they evolve):
   <https://github.com/nix-community/nixos-anywhere>.

After kexec, confirm the node is still up on the tailnet before disko runs:
`ssh root@<TARGET> tailscale status`.

## Phase 6 — Post-install handoff

- `nixos-rebuild list-generations` (or check `ssh` works) to confirm success.
- Set UEFI boot order to the new ESP disk if needed.
- For on-box management later: clone the repo into the user's home and use `nh`.
  Note `programs.nh.flake` rejects a path ending in `.nix` — if the repo dir ends
  in `.nix`, symlink `/etc/nixos -> ~/<repo>` and point `NH_FLAKE=/etc/nixos`.
- Tell the user which layers to add next (desktop, Home Manager, sops-nix secrets)
  as **separate** follow-up work, keeping this base untouched.

## Pitfalls (learned the hard way)

- **Idle auto-suspend** can take a headless box fully offline (looks like a
  crash). If headless, mask sleep:
  `systemd.targets.{sleep,suspend,hibernate,hybrid-sleep}.enable = false`.
- **Stripe = total loss** if either disk dies; recommend off-box `zfs send` backups.
- Use **`/dev/disk/by-id`** everywhere; `/dev/sdX` names are not stable.
- `nixos-anywhere` has **no build `--sudo`** semantics for kexec — it wants root;
  use `--sudo` only for the privilege-escalation path, and prefer a root key.
- macOS controller: `TMPDIR=/tmp`, and clear stale `known_hosts` entries when a
  DHCP IP gets reused.
- Don't blind-run a long deploy in a non-interactive terminal and assume failure
  on timeout — activation often completes on the box; check `list-generations`.
- Keep the first generation minimal. Adding desktop/HM/secrets later is easier to
  debug than a giant first install.
