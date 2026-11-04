# avocado — NixOS (ZFS) via nixos-anywhere

NixOS configuration for the host **avocado** (Intel i7-8550U, UEFI, ZFS root),
installed onto an existing Ubuntu box with
[`nixos-anywhere`](https://github.com/nix-community/nixos-anywhere).

The flake also defines two k3s agents, **g8way** (Intel NUC jumpbox) and
**headless** (disposable HP laptop). Both run NixOS with sops and Tailscale,
and g8way also has its desktop/jumpbox layer (Cinnamon, Home Manager, cluster
tools + kubeconfig). Since 2026-11-04 both are **joined to k3s** over the
tailnet, tainted so that nothing schedules there unless it opts in.
avocado stays the only k3s server and keeps every workload.
See [`docs/nodes.md`](docs/nodes.md).

## Layout

```
flake.nix                     inputs: nixpkgs (unstable), disko, nixos-anywhere
hosts/avocado/
  default.nix                 host entry point (imports modules)
  hardware.nix                boot/kernel/ZFS hostId/microcode
  disko.nix                   ZFS partition + pool/dataset layout
hosts/g8way/                  Intel NUC5 jumpbox + k3s agent (same 3 files)
hosts/headless/               HP laptop, disposable k3s agent (same 3 files)
modules/
  base.nix                    nix settings, gc, packages, firewall
  ssh.nix                     OpenSSH (key-only)
  zfs.nix                     scrub / trim / auto-snapshot
  tailscale.nix               tailscale service
  k3s.nix                     k3s server (avocado, control plane)
  k3s-agent.nix               k3s agent, tainted opt-in only (g8way, headless)
  k3s-common.nix              shared: token, node-ip + flannel over tailscale0
  desktop-cinnamon.nix        Cinnamon + LightDM, PipeWire, Bluetooth (g8way)
  jumpbox.nix                 cluster tools + sops-delivered admin kubeconfig (g8way)
  care-box.nix                control plane for the Pi lumine: host key + nightly backup pull
users/rithviknishad.nix       user + authorized SSH key
lumine/                       Raspberry Pi lumine (Raspberry Pi OS): CARE in a box at
                              care-box.rithviknishad.dev, driven from here by `just box-*`
                              (docs/care-box.md)
```

## Disk layout

Single ZFS pool **`rpool` striped across BOTH disks** for maximum capacity
(~342 GB usable):

- `sda` (120 GB WD) — ESP (`/boot`) + zfs partition
- `sdb` (250 GB Crucial) — whole-disk zfs partition

**No redundancy.** A stripe means losing *either* disk destroys the *entire*
pool, including the OS. disko **erases both disks**. Keep off-box backups
(`zfs send`) for anything important.

## Install (run from this directory)

The Ubuntu box currently needs a sudo password, so run nixos-anywhere with
`--sudo`, or enable temporary root SSH first.

```sh
nix run github:nix-community/nixos-anywhere -- \
  --flake .#avocado \
  --build-on remote \
  --sudo \
  rithviknishad@avocado.local
```

`--build-on remote` builds on the target (x86_64), avoiding a cross-build from
this arm64 Mac.

## Secrets (sops-nix + age)

Enter the dev shell first — it puts `sops`, `age`, `ssh-to-age`, `mkpasswd`,
`nixos-anywhere`, and `nixfmt` on `PATH` and sets `SOPS_AGE_KEY_FILE`:

```sh
nix develop           # or: direnv allow  (auto-loads via .envrc)
```

Inside the shell, common tasks are wrapped in a `justfile` — run `just` to list
them:

| Command | Action |
|---|---|
| `just deploy` | build on the box + activate (`switch`) |
| `just boot` | stage for next boot (safe for risky changes) |
| `just dry` | preview what would change |
| `just rollback` | revert the box to the previous generation |
| `just eval` | evaluate the config locally (no build) |
| `just secrets` | edit `secrets/avocado.yaml` |
| `just passwd` | generate a SHA-512 password hash |
| `just generations` | list the box's generations |
| `just ssh` / `just ssh-root` | SSH into the box |
| `just logs [unit]` | tail the box's journal |
| `just update [input]` | update flake inputs |
| `just fmt` | format Nix files |

Recipes default to avocado. Target another host with overrides, e.g.
`just host=g8way addr=g8way.local deploy` (see
[`docs/deployment.md`](docs/deployment.md#targeting-another-host)).

Secrets are stored encrypted per host in `secrets/<hostname>.yaml`
(`secrets/avocado.yaml`, `secrets/headless.yaml`, `secrets/g8way.yaml`), keyed by age recipients
in `.sops.yaml`:

- **admin** key: `~/.config/sops/age/keys.txt` (this Mac) — edit secrets
- **avocado** key: `avocado:/var/lib/sops-nix/key.txt` — decrypts at boot
- **other hosts**: an age recipient derived from the SSH host key
  (`ssh-keyscan -t ed25519 <ip> | ssh-to-age`); a reinstall changes it, so
  update `.sops.yaml` and rekey. See [`docs/secrets.md`](docs/secrets.md).

Edit secrets (inside `nix develop`, so `SOPS_AGE_KEY_FILE` is already set):

```sh
sops secrets/avocado.yaml
```

Generate a login/sudo password hash to paste in:

```sh
mkpasswd -m sha-512
```

Wiring: `modules/sops.nix` sets the user's `hashedPasswordFile` from
`config.sops.secrets."users/rithviknishad/hashed-password".path` (kept out of
`users/rithviknishad.nix` so hosts without a sops key yet can import the
user).

## Day-2 workflow

```sh
nixos-rebuild switch \
  --flake .#avocado \
  --target-host rithviknishad@avocado.local \
  --build-host rithviknishad@avocado.local \
  --use-remote-sudo
```

## Docs

In-depth documentation lives in [`docs/`](docs/) and is published to GitHub
Pages (built with the just-the-docs Jekyll theme via
`.github/workflows/pages.yml`). Enable it once under **Settings -> Pages ->
Build and deployment -> Source: GitHub Actions**; every push that touches
`docs/` then rebuilds the site.

Every publicly exposed app is listed, with live cluster stats, at
<https://apps.rithviknishad.dev> (Homepage, `k8s/homepage/`; see
[`docs/apps.md`](docs/apps.md)).

## Post-install checklist

- [ ] SSH back in as `rithviknishad`
- [ ] Set UEFI boot order to boot from the new pool's disk (sda ESP)
- [ ] `sudo tailscale up` to re-join the tailnet
- [ ] Re-create any Docker workloads (not yet ported)
- [ ] Set up off-box `zfs send` backups (no on-disk redundancy)
