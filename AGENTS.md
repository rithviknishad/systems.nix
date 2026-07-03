# AGENTS.md — rules for AI agents working in this repo

This repo is the declarative source of truth for the host **avocado**
(NixOS, ZFS root, k3s) and the user environment (Home Manager). It is managed
almost entirely through AI agents — follow these rules strictly.

## Repo map

| Path | Purpose |
|---|---|
| `flake.nix` | inputs + `nixosConfigurations.avocado` + standalone HM config + devshell |
| `hosts/avocado/` | host-specific: entry point, hardware, disko (disk layout) |
| `modules/` | one file per system concern (ssh, zfs, k3s, tailscale, sops, ...) |
| `home/rithviknishad/` | Home Manager; one dir per app under `apps/<app>/` |
| `users/` | user accounts + SSH keys |
| `secrets/` | sops-encrypted secrets (age); recipients in `.sops.yaml` |
| `k8s/` | Kubernetes workloads on k3s (kustomize + helmfile) |
| `docs/` | Jekyll site (just-the-docs), published to GitHub Pages |
| `justfile` | ALL common operations — check here before inventing commands |

## Golden rules

1. **Docs stay in sync — always.** Any change to config, workflows, disk
   layout, secrets wiring, or k8s must update the relevant page(s) in
   `docs/`, and `README.md` / `justfile` comments if affected. New
   functionality → add docs; removed functionality → remove docs. A change
   without its doc update is an incomplete change.
2. **Commit every atomic change once it's verified working.** Commits are
   the rollback mechanism here. One logical change per commit; never bundle
   unrelated edits. Verify first (see "Validation"), then commit. Match the
   existing style: short, lowercase, imperative (e.g. `setup kiosk`,
   `add zfs snapshot alerts`).
3. **Never commit plaintext secrets.** Secrets go through sops
   (`secrets/*.yaml`, edited via `just secrets` / `just mon-secrets`).
   Never print decrypted secret values into the chat, logs, or files.
   Never touch age private keys. Check `git status` for stray secret files
   before every commit.
4. **Ask before destructive or live-impacting actions.** Never run without
   explicit confirmation: `just install` / nixos-anywhere (wipes both
   disks), `just deploy` (activates on the live box), disko changes,
   `just update` (bumps flake.lock), `mon-destroy`, or anything deleting
   k8s resources or ZFS datasets. Prefer `just dry` or `just boot` for
   risky changes.

## Workflow

- Work inside the devshell (`nix develop`, or direnv auto-loads it); all
  tools (sops, nixfmt, kubectl, helmfile, ...) live there.
- Prefer `just` recipes over raw commands. If a new operation becomes
  routine, add a recipe to `justfile` (with a comment) and document it.
- Typical loop: edit → `nix fmt` → `just eval` → commit → (user deploys, or
  deploy on request with confirmation).

## New service checklist

When adding (or removing) any service — k8s workload, NixOS service module,
or anything exposed via ingress/tunnel — walk this list and ask the user
about any item you skip:

1. **Monitoring (Gatus).** Every user-facing or long-running service should
   get an uptime probe in `k8s/monitoring/gatus.yaml`. Prefer a real health
   endpoint (e.g. Immich's `/api/server/ping`) over `/`, pick the right
   group (`internal` for in-cluster svc URLs, `public` for edge URLs), and
   add `[CERTIFICATE_EXPIRATION]` checks for public HTTPS endpoints.
   Gotcha: bump the `checksum/config` annotation in the gatus Deployment or
   the pod won't pick up the new ConfigMap.
2. **Alerts/metrics.** If the service exports metrics or has failure modes
   worth paging on, consider a VMRule/scrape config alongside the existing
   ones in `k8s/monitoring/`.
3. **Ingress/exposure.** Local (`*.avocado.local`), Tailscale, or public via
   cloudflared — be deliberate; public exposure needs user confirmation.
4. **Secrets** via sops (see below), never inline.
5. **Docs** — golden rule #1; usually `docs/kubernetes.md` or a new page.
6. Removing a service? Remove its Gatus endpoint, alerts, ingress, secrets,
   and docs too — dead probes cause alert noise, which erodes trust in the
   ntfy topic.

## Validation (before any commit)

1. `nix fmt` — formatting is nixfmt, enforced via the flake formatter.
2. `just eval` — evaluates the full system config locally (fast, no build).
   This must pass; it catches most Nix errors without touching the box.
3. For Home Manager-only changes, evaluating
   `.#homeConfigurations."rithviknishad@avocado"` also works.
4. For k8s changes: `kubectl kustomize k8s/<dir>` (or
   `helmfile -f ... diff` for helm changes) to check they render.
5. Only claim something works if the check actually passed.

## Nix conventions

- **Modules are small and single-purpose.** New system concern → new file in
  `modules/`, imported from `hosts/avocado/default.nix`. Don't grow
  `base.nix` into a dumping ground.
- **Home Manager apps** each get `home/rithviknishad/apps/<app>/default.nix`,
  imported from `home/rithviknishad/default.nix`.
- **Host-specific vs reusable:** hardware, disko, and anything
  avocado-specific stays in `hosts/avocado/`; everything else should be
  host-agnostic in `modules/` (a second host may be added later).
- Prefer NixOS/HM options over `environment.etc` hacks, systemd unit
  overrides over shell scripts, and declarative config over imperative
  state on the box.
- New flake inputs must set `inputs.nixpkgs.follows = "nixpkgs"`.
- Never edit `flake.lock` by hand — only via `just update [input]`.
- Comments explain *why* (tradeoffs, gotchas), not what the code does. This
  repo leans on comments as institutional memory — keep that up.

## Secrets (sops-nix)

- Recipients live in `.sops.yaml` (admin key on the Mac, host key on
  avocado). Changing recipients requires `just secrets-rekey`.
- Wire secrets into NixOS via `config.sops.secrets."<name>".path` — never
  interpolate secret values into the Nix store.
- k8s secrets: sops-encrypted in `secrets/`, decrypted at deploy time (see
  `mon-deploy`); the decrypted files are gitignored — keep it that way.

## docs/ specifics

- Pages: architecture, deployment, home-manager, kubernetes, monitoring,
  networking, nix-modules, secrets, storage. Add new pages with the
  just-the-docs front matter used by existing ones (`nav_order` etc.).
- `README.md` is the quick-start; `docs/` is the deep dive. Big-picture
  changes usually touch both.

## Things agents must NOT do

- Push to remotes unless explicitly asked.
- Reboot the box, modify ZFS pools/datasets, or change UEFI/boot behavior
  without confirmation.
- Disable or weaken: SSH key-only auth, the firewall, sops encryption,
  networkpolicies in k8s.
- "Fix" a failing deploy by rolling back declarative config to match
  imperative state on the box — the repo is the source of truth.
