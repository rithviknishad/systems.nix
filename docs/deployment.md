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
  `--build-on remote`).

### Post-install checklist

- [ ] SSH back in as `rithviknishad`.
- [ ] Set the UEFI boot order to the new pool's disk (the `sda` ESP).
- [ ] `sudo tailscale up` to (re)join the tailnet.
- [ ] Provision the host **age key** at `/var/lib/sops-nix/key.txt` so
      [secrets](secrets.md) decrypt.
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
| `just mon-destroy` | remove the CR layer + helm release |

> The `justfile` connects over Tailscale MagicDNS (`avocado`) and disables
> `known_hosts` checking (`NIX_SSHOPTS`) so deploys don't trip over stale host
> keys.

## Deploying the Kubernetes workloads

```sh
just kubeconfig                    # once
kubectl apply -f k8s/sample.yaml   # smoke test
kubectl apply -k k8s/immich        # after creating k8s/immich/secret.yaml
just mon-deploy                    # monitoring stack
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
