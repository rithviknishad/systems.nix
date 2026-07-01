---
title: Home Manager
layout: default
nav_order: 4
---

# Home Manager

The user environment for `rithviknishad` is managed by
[Home Manager](https://github.com/nix-community/home-manager). The profile lives
in `home/rithviknishad/` and is composed of one small module per app under
`apps/`. It targets Home Manager release `26.05` (`home.stateVersion`).

It ships two ways (see [the flake](nix-modules.md#the-flake-flakenix)):

- **System-wide** with `nixos-rebuild` / `nh os switch` via
  `modules/home-manager.nix`.
- **Standalone** with `nh home switch` via the flake's `homeConfigurations`
  output — fast iteration on dotfiles without a full rebuild.

## App modules at a glance

| Module | What it configures |
|---|---|
| `git` | identity, `main` default branch, `pull.rebase`, `push.autoSetupRemote`, `fetch.prune` |
| `kitty` | terminal — JetBrainsMono Nerd Font, Catppuccin-Mocha theme, 10k scrollback |
| `firefox` | hardened/privacy Firefox via enterprise policies + locked prefs |
| `zeditor` | Zed editor — no telemetry, One Dark, vim mode off |
| `zsh` | zsh + oh-my-zsh (`robbyrussell`), history, aliases, autosuggest, syntax highlight |
| `ssh` | client config; identity file from the sops-delivered key |
| `direnv` | `direnv` + `nix-direnv`, wired into zsh |
| `gnome` | dconf tweaks to stop idle screen-blanking/power actions |
| `opencode` | installs the `opencode` terminal AI agent |
| `lens` | installs Lens (Kubernetes IDE, unfree) |
| `claude-code` | installs Claude Code (unfree) |

## Notable details

### Shell (`zsh`)

zsh is enabled at the **system** level too (`programs.zsh.enable` in
`users/rithviknishad.nix`) so it's a valid login shell; Home Manager then
configures it. Highlights: 50k shared history with dedup, oh-my-zsh with the
`git` and `sudo` plugins, and aliases `ll`, `la`, `gs`, `gd`.

### SSH client (`ssh`)

The module is deliberately **machine-agnostic**: it only *references* the
private key path `/run/secrets/rithviknishad/ssh_id_ed25519`. The key itself is
delivered out-of-band by [sops-nix](secrets.md) at the system level. It defines
its own `*` defaults (agent forwarding off, connection multiplexing via a
`ControlMaster` socket, keepalives) and a `github.com` block using that
identity.

### Firefox (`firefox`)

A privacy-hardened Firefox adapted from
[recipes.nix](https://codeberg.org/adtya/recipes.nix), expressed as:

- **Enterprise policies** (`policies.nix`): disables telemetry, Pocket,
  Firefox Accounts, form history, and the built-in AI/"GenerativeAI" features;
  forces tracking protection; blocks arbitrary extension installs and
  force-installs an allow-list (uBlock Origin, Privacy Badger, Bitwarden,
  Dracula theme); replaces the default search engines with a curated set of
  keyword engines (`@np` Nix Packages, `@no` Nix Options, `@gh` GitHub, …).
- **Locked preferences** (`prefs.nix`): the `user.js`-style profile settings.

### GNOME idle (`gnome`)

Complements the system-level sleep masking in
[`desktop.nix`](nix-modules.md#desktopnix--gnome-workstation). System suspend is
already blocked; this module disables the *per-user* GNOME behaviours that
remain — screen blanking on idle, idle dimming, and idle power actions — so the
session (and the services it hosts) stays awake indefinitely.

## Adding an app

1. Create `home/rithviknishad/apps/<name>/default.nix` with a Home Manager
   module (either configure a `programs.<name>` block or add to
   `home.packages`).
2. Add `./apps/<name>` to the `imports` list in
   `home/rithviknishad/default.nix`.
3. Apply with `nh home switch` (user-only) or `just deploy` (full system).
