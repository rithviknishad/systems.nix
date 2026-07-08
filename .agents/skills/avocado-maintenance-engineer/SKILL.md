---
name: avocado-maintenance-engineer
description: Operational playbook for routine maintenance and troubleshooting of the avocado host (NixOS/ZFS root/k3s) and its Home Manager + Kubernetes config. Use when deploying config changes, updating flake inputs, responding to ntfy/Gatus alerts, diagnosing service/cluster/ZFS/network issues, rotating or wiring secrets, or performing any day-2 operation on the box.
---

# avocado maintenance engineer

You are doing day-2 operations on **avocado** (NixOS, ZFS root, single-node
k3s). This skill is the operational playbook. The always-on rules in the repo
root `AGENTS.md` still apply in full — this skill does NOT restate them, it
tells you how to actually carry out maintenance work safely.

## Prime directives (read first)

- `AGENTS.md` governs. Especially: docs stay in sync, keep changes atomic and
  self-contained, never expose plaintext secrets, and **ask before
  destructive or live-impacting actions**.
- The repo is the source of truth. Never reshape declarative config to match
  drifted state on the box. Fix the config, then deploy.
- Work inside the devshell (`nix develop` / direnv). All tools live there.
- Prefer `just` recipes over raw commands. Run `just` to list them.

## The safe change loop

For any config edit (NixOS module, Home Manager app, hardware, disko):

1. Edit the smallest relevant file (`modules/` for system concerns,
   `home/rithviknishad/apps/<app>/` for HM apps).
2. `nix fmt` — always.
3. `just eval` — must pass. For HM-only changes you may also eval
   `.#homeConfigurations."rithviknishad@avocado"`.
4. Show the user the diff / plan. For anything risky prefer `just dry`
   (preview) or `just boot` (stage for next boot) over `just deploy`.
5. `just deploy` **only with explicit confirmation** — it activates on the
   live box.
6. Update the relevant `docs/` page(s) (+ `README.md`/`justfile` if affected).

Keep each change atomic and self-contained so it's easy to review and undo.
Leave version control to the user.

`just rollback` reverts the box to its previous generation;
`just generations` lists them. Rollback is a live action — confirm first.

## Diagnostic toolbox (where to look)

Run `just kubeconfig` once, then use `KUBECONFIG=~/.kube/avocado`.

| Symptom | First look |
|---|---|
| Alert fired on ntfy | Identify topic: `avocado-alerts` (ours) vs `avocado-abdm` (3rd-party). Find the matching Gatus endpoint or VMRule. |
| Service down / flaky | `just mon-gatus` (uptime dashboard), then `kubectl -n <ns> get pods` + `kubectl -n <ns> logs`. |
| Host/service metrics | `just mon-grafana` (dashboards). |
| Logs (cluster-wide) | `just mon-logs` → VictoriaLogs UI at `/select/vmui`. |
| NixOS service / unit | `just logs [unit]` (tails the box journal). |
| ntfy bridge itself | `just mon-ntfy-logs`; test with `just mon-ntfy-test`. |
| k8s manifest renders? | `kubectl kustomize k8s/<dir>` (helm: `helmfile -f ... diff`). |
| ZFS pool health | `just ssh-root` then `zpool status` / `zfs list`. Read-only inspection is fine; **never** modify pools/datasets without confirmation. |

## Common playbooks

**Update flake inputs.** `just update [input]` bumps `flake.lock` — this is a
confirm-first action (AGENTS.md). After: `nix fmt`, `just eval`, then
`just boot` or `just dry` before a full deploy so a bad bump can't brick the
live activation. Keep the `flake.lock` bump as its own atomic change.

**Add / remove a service.** Walk the "New service checklist" in `AGENTS.md`
(Gatus probe, alerts, exposure, secrets, docs, symmetric removal). Deploy per
the safe change loop. Removing a service means also deleting its Gatus
endpoint (and bumping `checksum/config` in the gatus Deployment), VMRules,
ingress, secrets, and docs — dead probes create alert noise.

**Rotate / wire a secret.** Edit via `just secrets` (host) or
`just mon-secrets` (monitoring). Wire into NixOS through
`config.sops.secrets."<name>".path` — never interpolate secret values into the
Nix store or manifests. After changing recipients in `.sops.yaml`, run the
matching `*-rekey` recipe. Never print decrypted values into chat/logs/files,
and never leave stray decrypted files in the tree (`values-secret.yaml`,
`k8s/immich/secret.yaml` are gitignored — keep it that way).

**Respond to an alert.** Find the source (Gatus endpoint or VMRule) → confirm
it's a real failure via Grafana/logs, not a flapping probe → fix root cause in
config → deploy → verify the probe recovers (Gatus resolves after 2 successes,
`send-on-resolved` pushes the recovery). If the alert itself is wrong (bad
threshold), fix the rule and document why.

**Deploy monitoring changes.** `just mon-deploy` (decrypts the Grafana
password, applies namespace + helmfile + kustomize). ConfigMap-only changes to
Gatus won't roll the pod unless you bump the `checksum/config` annotation.

## Confirmation gates (never do these silently)

`just install` / nixos-anywhere (wipes both disks), `just deploy`, `just boot`,
`just update`, disko edits, `mon-destroy`, deleting any k8s resource or ZFS
dataset, rebooting the box, or changing UEFI/boot/firewall/SSH-auth behavior.
Present the plan and wait for an explicit go-ahead.

## Definition of done

- `nix fmt` clean, `just eval` (and k8s render, if touched) passing.
- Docs updated in the same change.
- Atomic, self-contained change; working tree clean of secrets.
- If deployed: the box activated cleanly and the relevant Gatus/Grafana signal
  is healthy.
