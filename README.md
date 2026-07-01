# avocado — NixOS (ZFS) via nixos-anywhere

NixOS configuration for the host **avocado** (Intel i7-8550U, UEFI, ZFS root),
installed onto an existing Ubuntu box with
[`nixos-anywhere`](https://github.com/nix-community/nixos-anywhere).

## Layout

```
flake.nix                     inputs: nixpkgs (unstable), disko, nixos-anywhere
hosts/avocado/
  default.nix                 host entry point (imports modules)
  hardware.nix                boot/kernel/ZFS hostId/microcode
  disko.nix                   ZFS partition + pool/dataset layout
modules/
  base.nix                    nix settings, gc, packages, firewall
  ssh.nix                     OpenSSH (key-only)
  zfs.nix                     scrub / trim / auto-snapshot
  tailscale.nix               tailscale service
users/rithviknishad.nix       user + authorized SSH key
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

Secrets are stored encrypted in `secrets/avocado.yaml`, keyed by age recipients
in `.sops.yaml`:

- **admin** key: `~/.config/sops/age/keys.txt` (this Mac) — edit secrets
- **host** key: `avocado:/var/lib/sops-nix/key.txt` — decrypts at boot

Edit secrets (inside `nix develop`, so `SOPS_AGE_KEY_FILE` is already set):

```sh
sops secrets/avocado.yaml
```

Generate a login/sudo password hash to paste in:

```sh
mkpasswd -m sha-512
```

Wiring: `users/rithviknishad.nix` reads the hash via
`config.sops.secrets."users/rithviknishad/hashed-password".path`.

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

## Post-install checklist

- [ ] SSH back in as `rithviknishad`
- [ ] Set UEFI boot order to boot from the new pool's disk (sda ESP)
- [ ] `sudo tailscale up` to re-join the tailnet
- [ ] Re-create any Docker workloads (not yet ported)
- [ ] Set up off-box `zfs send` backups (no on-disk redundancy)
