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

## Mirroring to GitHub

This repo is hosted on [Tangled](https://tangled.org) and mirrored to
[`github.com/rithviknishad/systems.nix`](https://github.com/rithviknishad/systems.nix)
by a [Spindle](https://docs.tangled.org/spindles) pipeline
(`.tangled/workflows/mirror-github.yml`). On every push to `main`, the pipeline
force-pushes the branch and tags to GitHub, keeping the two in sync.

Secrets use **sops**: the GitHub token is stored encrypted in-repo at
`secrets/ci.yaml` (recipients `admin` + `ci`). The only thing stored on Tangled
is the **CI age private key** as the secret `SOPS_AGE_KEY`, which the spindle
uses to decrypt `secrets/ci.yaml` at run time. The PAT never lives in plaintext
anywhere.

One-time setup:

1. Create the (empty) repo `github.com/rithviknishad/systems.nix`.
2. Create a [fine-grained GitHub PAT](https://github.com/settings/personal-access-tokens)
   scoped to **only** that repo, with **Contents: Read and write**.
3. Store the PAT in `secrets/ci.yaml` (inside `nix develop`):

   ```sh
   just secrets-ci      # opens the encrypted file in your editor
   ```

   Set `github.mirror-token` to the PAT value.
4. In the Tangled repo, go to **settings -> pipelines**:
   - select a spindle (e.g. `spindle.tangled.sh`),
   - add a secret named `SOPS_AGE_KEY` holding the CI age **private** key
     (the `AGE-SECRET-KEY-...` line from `ci-age-key.txt`).
5. Push to `main`; watch the run under the repo's **pipelines** tab.

The CI age key was generated with `just ci-keygen`; its public key lives in
`.sops.yaml` as `&ci`. The private key file `ci-age-key.txt` is gitignored ---
upload it to Tangled once, then you can delete the local copy (regenerate any
time with `just ci-keygen` + `just secrets-ci-rekey`).

GitHub is treated as a downstream mirror only: pushes there can be overwritten,
so never commit directly to the GitHub copy.

The pipeline is written so the decrypted PAT never reaches the logs: it stays in
a shell variable and a `0600` credentials file (read by git's `store` helper),
never in a command argument or the remote URL. git redacts the Authorization
header, so even `GIT_TRACE`/`GIT_CURL_VERBOSE` output is safe.

## Post-install checklist

- [ ] SSH back in as `rithviknishad`
- [ ] Set UEFI boot order to boot from the new pool's disk (sda ESP)
- [ ] `sudo tailscale up` to re-join the tailnet
- [ ] Re-create any Docker workloads (not yet ported)
- [ ] Set up off-box `zfs send` backups (no on-disk redundancy)
