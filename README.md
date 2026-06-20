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

## Day-2 workflow

```sh
nixos-rebuild switch \
  --flake .#avocado \
  --target-host rithviknishad@avocado.local \
  --build-host rithviknishad@avocado.local \
  --use-remote-sudo
```

## Post-install checklist

- [ ] SSH back in as `rithviknishad`
- [ ] Set UEFI boot order to boot from the new pool's disk (sda ESP)
- [ ] `sudo tailscale up` to re-join the tailnet
- [ ] Re-create any Docker workloads (not yet ported)
- [ ] Set up off-box `zfs send` backups (no on-disk redundancy)
