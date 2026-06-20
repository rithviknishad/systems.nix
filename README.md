# avocado — NixOS (ZFS) via nixos-anywhere

NixOS configuration for the host **avocado** (Intel i7-8550U, UEFI, ZFS root),
installed onto an existing Ubuntu box with
[`nixos-anywhere`](https://github.com/nix-community/nixos-anywhere).

## Layout

```
flake.nix                     inputs: nixpkgs (25.05), disko, nixos-anywhere
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

## Disk target

disko erases **sda** (`ata-WDC_WDS120G2G0A-00JH30_182216805738`, the empty 120GB WD).
Ubuntu on sdb (250GB Crucial) is left untouched as a fallback. Change the disk in
`hosts/avocado/disko.nix` if needed.

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
- [ ] Set UEFI boot order to the new disk (sda)
- [ ] `sudo tailscale up` to re-join the tailnet
- [ ] Re-create any Docker workloads (not yet ported)
