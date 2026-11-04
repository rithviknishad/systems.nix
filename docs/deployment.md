---
title: Deployment & operations
layout: default
nav_order: 10
---

# Deployment & operations

Everything here runs from inside the dev shell (`nix develop`, or `direnv allow`
to auto-load via `.envrc`), which provides all the tooling. Most tasks are
wrapped in the `justfile` — run `just` to list them.

## First install (bare metal → NixOS)

`avocado` is installed onto an existing box with
[nixos-anywhere](https://github.com/nix-community/nixos-anywhere). This
**erases both disks** and lays down the [ZFS layout](storage.md).

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#avocado \
  --build-on remote \
  --sudo \
  rithviknishad@avocado.local
```

- `--build-on remote` builds on the x86_64 target, avoiding a cross-build from
  an arm64 Mac.
- `--sudo` is used because the source box needs a sudo password (or enable
  temporary root SSH first).
- There's also a `just install` recipe (targets `root@avocado`,
  `--build-on remote`). With overrides it installs the other hosts too (see
  [below](#targeting-another-host)).

### Installing from avocado (`--build-on local`)

[g8way and headless](nodes.md) were installed by running nixos-anywhere
**on avocado** and building there, rather than on the target:

```sh
# on avocado; ERASES the target disk, confirm first
nix run github:nix-community/nixos-anywhere -- \
  --flake .#g8way --build-on local -L \
  --kexec-extra-flags "--kexec-syscall" \
  --ssh-option ControlPath=none \
  root@192.168.165.36
```

- `--build-on local` builds the closure on the machine running
  nixos-anywhere and copies it over. avocado is x86_64 with a warm store, so
  nothing has to build inside the target's RAM-only installer. This only
  works from an x86_64 Linux machine, not the arm64 Mac.
- The cost is the copy. The ~2.3 GiB closure took about 23 minutes to upload
  over the LAN, so a long, quiet copy step is normal.
- `--ssh-option ControlPath=none` works around the
  [ControlMaster bug](#ssh-controlmaster-bug-on-avocado) when running from
  avocado.
- `--kexec-extra-flags "--kexec-syscall"` is only needed on hardware that
  hangs at kexec (below). headless installed without it.

### Install pitfalls

- **kexec can hang the box.** nixos-anywhere first kexecs from the existing OS
  into its installer. On g8way (Intel NUC5) the handover from Linux Mint's 7.0
  kernel **froze the machine**: no network, and a power cycle was the only way
  out. disko hadn't started, so the disk was untouched. The fix was
  `--kexec-extra-flags "--kexec-syscall"`, which makes kexec use the older
  `kexec_load` syscall instead of the auto-picked `kexec_file_load`. If a
  target goes silent right after the kexec step, power-cycle it and retry
  with that flag.
- **A reinstall changes the SSH host key**, and therefore the age recipient of
  hosts that decrypt with it (g8way/headless). Update `.sops.yaml` and rekey
  before deploying the sops layer again (see
  [Secrets](secrets.md#per-host-recipients-and-files)).

### Post-install checklist

- [ ] SSH back in as `rithviknishad`.
- [ ] Set the UEFI boot order to the new pool's disk (the `sda` ESP).
- [ ] `sudo tailscale up` to (re)join the tailnet.
- [ ] Provision the host **age key** at `/var/lib/sops-nix/key.txt` so
      [secrets](secrets.md) decrypt. (avocado only. g8way/headless decrypt
      with their SSH host key: add its recipient to `.sops.yaml` and rekey
      instead.)
- [ ] Set up **off-box `zfs send` backups** — the pool has no redundancy.
- [ ] Deploy the [k3s workloads](kubernetes.md) and
      [monitoring stack](monitoring.md).

## Day-2: change the system

Edit the Nix files, then apply. Two equivalent paths:

**From your Mac (remote build + activate):**

```sh
just deploy     # nixos-rebuild switch, building ON the box
just boot       # stage for next boot without activating now (safe for risky changes)
just dry        # preview what activating would change
just rollback   # revert the box to the previous generation
```

**On the box itself (via `nh`, pointed at `/etc/nixos`):**

```sh
nh os switch    # build + activate
nh os boot      # stage for next boot
nh os build     # build only (no sudo)
```

Sanity-check without deploying:

```sh
just eval       # evaluate the whole config locally (no build)
just fmt        # format all Nix files (nix fmt)
just generations
```

## Targeting another host

The `justfile` defaults to avocado, but its `host` and `addr` variables can be
overridden on the command line. `host` picks the flake output
(`.#<host>`); `addr` is where SSH connects (as `root@<addr>`, or
`rithviknishad@<addr>` for `just ssh`). This is how
[g8way and headless](nodes.md) are handled:

```sh
just host=g8way eval                                    # evaluate .#g8way locally
just host=<host> addr=<lan-ip> install                  # DESTROYS the disk, confirm first
just host=g8way  addr=192.168.165.36 ssh-root
```

- Use the LAN IP (or `.local` name) until the host is on Tailscale. Only
  avocado has a MagicDNS name today.
- System recipes follow the overrides: `eval`, `deploy`, `boot`, `dry`,
  `rollback`, `generations`, `ssh`, `ssh-root`, `logs`, `install`.
- Secrets recipes always edit `secrets/avocado.yaml`. For another host, run
  `sops secrets/<hostname>.yaml` directly. The k8s recipes always
  use `~/.kube/avocado` (the cluster lives on avocado). Don't pass `host=`
  to `kubeconfig`: it reads `/etc/rancher/k3s/k3s.yaml` from `<addr>`, and
  only avocado has one.

### Deploying to g8way and headless

`just deploy` builds **on the target** (`--build-host`). For the new hosts we
build on avocado instead and push the result, the same trade as the install.
This keeps compiles off the small i3s (and off headless's worn-out SSD). Run
it from avocado, with no `--build-host`:

```sh
# on avocado
NIX_SSHOPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ControlPath=none" \
  nixos-rebuild switch --flake .#headless --target-host root@192.168.165.200
```

This is plain `nixos-rebuild`, not a just recipe, so `NIX_SSHOPTS` from the
shell *does* apply here. Swap `switch` for `boot` or `dry-activate` as with
the recipes.

### SSH ControlMaster bug on avocado

Running recipes **from avocado** can fail with
`mm_send_fd: sendmsg: Message too long` (`mux_client_request_session: send
fds failed`). The cause is the `ControlMaster auto` multiplexing in the Home
Manager [ssh module](home-manager.md#ssh-client-ssh). The workaround is
`-o ControlPath=none`, which bypasses the mux socket. How to pass it depends on
the recipe:

- `deploy` / `boot` / `dry` use `nixos-rebuild`, which reads `NIX_SSHOPTS`.
  `rollback` / `generations` / `ssh` / `ssh-root` / `logs` splice
  `NIX_SSHOPTS` straight into their `ssh` command. The justfile **exports its
  own** `NIX_SSHOPTS`, so setting it in your shell has no effect. Override
  it as a just variable instead. The override replaces the default, so
  restate the known-hosts options:
  ```sh
  just NIX_SSHOPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ControlPath=none" \
    host=g8way addr=192.168.165.36 ssh-root
  ```
- `install` does **not** use `NIX_SSHOPTS`. nixos-anywhere builds its own SSH
  options (and already disables known-hosts checking). Run it directly and add
  `--ssh-option ControlPath=none`, as in
  [Installing from avocado](#installing-from-avocado---build-on-local).

## The `just` reference

### System

| Recipe | Action |
|---|---|
| `just deploy` | build on the box + activate (`switch`) |
| `just boot` | stage for next boot |
| `just dry` | preview changes (`dry-activate`) |
| `just rollback` | revert to previous generation |
| `just eval` | evaluate config locally (no build) |
| `just fmt` | format Nix files |
| `just update [input]` | update all flake inputs (or one) |
| `just generations` | list the box's generations |
| `just install` | fresh nixos-anywhere install (**destroys disks**) |

All of these accept `host=` / `addr=` overrides (see
[Targeting another host](#targeting-another-host)).

### Access & logs

| Recipe | Action |
|---|---|
| `just ssh` / `just ssh-root` | SSH as your user / as root |
| `just logs [unit]` | tail the box's journal (optionally one unit) |
| `just kubeconfig` | fetch kubeconfig to `~/.kube/avocado` (server → `avocado`) |

### Secrets

| Recipe | Action |
|---|---|
| `just secrets` / `just secrets-show` / `just secrets-rekey` | edit / view / re-encrypt `secrets/avocado.yaml` |
| `just mon-secrets*` | same for `secrets/monitoring.enc.yaml` |
| `just passwd` | generate a SHA-512 password hash |

### Monitoring

| Recipe | Action |
|---|---|
| `just mon-deploy` | namespace + helm release + CR layer |
| `just mon-status` | pods/svc/ingress/vmrule in `monitoring` |
| `just mon-grafana` | port-forward Grafana → `:3000` |
| `just mon-gatus` | port-forward Gatus → `:8080` |
| `just mon-logs` | port-forward VictoriaLogs → `:9428` |
| `just mon-ntfy-logs` | tail the ntfy bridge |
| `just mon-ntfy-test [topic]` | send a test push |
| `just mon-speedtest` | print the latest internet speedtest results |
| `just mon-destroy` | remove the CR layer + helm release |

> Only the recipes for the helmfile-based monitoring stack are listed here. Every
> other workload follows the same `<name>-deploy` / `-status` / `-logs` /
> `-secrets` shape — run `just --list` for the full set.

> The `box-*` recipes drive **lumine** (the Raspberry Pi running
> [CARE in a box](care-box.md)) instead: same machine you run them from
> (avocado or the Mac, the box's control plane), over SSH to `lumine`.

> The `justfile` connects over Tailscale MagicDNS (`avocado`) by default and
> disables `known_hosts` checking (`NIX_SSHOPTS`) so deploys don't trip over
> stale host keys (a reinstalled host has a new key).

## Deploying the Kubernetes workloads

```sh
just kubeconfig                    # once
kubectl apply -f k8s/sample.yaml   # smoke test
kubectl apply -k k8s/immich        # after creating k8s/immich/secret.yaml
just mon-deploy                    # monitoring stack (infra telemetry)
just apps-deploy                   # app gallery (apps.rithviknishad.dev)
```

See [Kubernetes](kubernetes.md) and [Monitoring](monitoring.md) for the
per-workload details.

## Publishing these docs to GitHub Pages

This `docs/` folder is a self-contained Jekyll site using the **just-the-docs**
theme (see `docs/Gemfile`). It's built and deployed by GitHub Actions
(`.github/workflows/pages.yml`).

1. Push the repo to GitHub (it's the primary now).
2. In the GitHub repo: **Settings → Pages → Build and deployment**.
3. Source: **GitHub Actions**.
4. Push any change under `docs/` (or run the workflow manually). The action
   builds the site and publishes it at
   `https://<user>.github.io/systems.nix/`.

Why Actions and not "deploy from a branch": the classic branch build only ships
a small set of built-in themes, so a gem-based `theme: just-the-docs` needs a
real Jekyll build. Mermaid diagrams render natively (configured in
`docs/_config.yml`), and relative `.md` links resolve via the
`jekyll-relative-links` plugin.

Preview locally:

```sh
cd docs
bundle install
bundle exec jekyll serve   # http://localhost:4000
```
