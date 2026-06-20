# Common commands for the avocado NixOS config.
# Run inside the dev shell (`nix develop` / direnv), where all tools live.
# List recipes with `just` or `just --list`.

host        := "avocado"
flake       := ".#" + host
# Connect over Tailscale MagicDNS — stable across DHCP/IP changes.
addr        := "avocado"
target      := "root@" + addr
user_target := "rithviknishad@" + addr
secrets     := "secrets/avocado.yaml"
ci_secrets  := "secrets/ci.yaml"

# Avoid stale known_hosts entries when deploying to the box.
export NIX_SSHOPTS := "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Show available recipes.
default:
    @just --list

# Build + activate the config on the box (build runs on the remote).
deploy:
    TMPDIR=/tmp nixos-rebuild switch --flake {{flake}} --target-host {{target}} --build-host {{target}}

# Stage the config for next boot without activating now (safe for risky changes).
boot:
    TMPDIR=/tmp nixos-rebuild boot --flake {{flake}} --target-host {{target}} --build-host {{target}}

# Show what activating would change, without committing to it.
dry:
    TMPDIR=/tmp nixos-rebuild dry-activate --flake {{flake}} --target-host {{target}} --build-host {{target}}

# Roll the box back to its previous generation.
rollback:
    ssh {{NIX_SSHOPTS}} {{target}} 'nixos-rebuild switch --rollback'

# Evaluate the full system config locally (no build) — fast sanity check.
eval:
    nix eval .#nixosConfigurations.{{host}}.config.system.build.toplevel.drvPath

# Format all Nix files.
fmt:
    nix fmt

# Update all flake inputs (or one: `just update nixpkgs`).
update *input:
    nix flake update {{input}}

# Edit the encrypted secrets file.
secrets:
    sops {{secrets}}

# View decrypted secrets (be mindful of your screen).
secrets-show:
    sops --decrypt {{secrets}}

# Re-encrypt secrets after changing recipients in .sops.yaml.
secrets-rekey:
    sops updatekeys {{secrets}}

# Edit the encrypted CI secrets file (GitHub mirror PAT, etc.).
secrets-ci:
    sops {{ci_secrets}}

# View decrypted CI secrets (be mindful of your screen).
secrets-ci-show:
    sops --decrypt {{ci_secrets}}

# Re-encrypt CI secrets after changing recipients in .sops.yaml.
secrets-ci-rekey:
    sops updatekeys {{ci_secrets}}

# Generate a fresh CI age keypair (private key -> ci-age-key.txt, gitignored).
# Then: add the public key to .sops.yaml as `&ci`, `just secrets-ci-rekey`, and
# upload the private key as Tangled secret SOPS_AGE_KEY.
ci-keygen:
    age-keygen -o ci-age-key.txt

# Generate a SHA-512 password hash to paste into secrets.
passwd:
    mkpasswd -m sha-512

# List the box's NixOS generations.
generations:
    ssh {{NIX_SSHOPTS}} {{target}} 'nixos-rebuild list-generations'

# SSH into the box as your user / as root.
ssh:
    ssh {{NIX_SSHOPTS}} {{user_target}}

ssh-root:
    ssh {{NIX_SSHOPTS}} {{target}}

# Tail the box's journal (optionally a unit: `just logs tailscaled`).
logs *unit:
    ssh {{NIX_SSHOPTS}} {{target}} 'journalctl -fb {{ if unit != "" { "-u " + unit } else { "" } }}'

# Fresh install onto the target with nixos-anywhere (DESTROYS both disks).
install:
    nix run github:nix-community/nixos-anywhere -- \
        --flake {{flake}} --build-on remote -L {{target}}
