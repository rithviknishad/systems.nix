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
| App gallery tile missing/wrong | `curl -s -H 'Host: apps.avocado.local' http://avocado/api/services` (what Homepage discovered), then `just apps-logs`. |
| ntfy bridge itself | `just mon-ntfy-logs`; test with `just mon-ntfy-test`. |
| k8s manifest renders? | `kubectl kustomize k8s/<dir>` (helm: `helmfile -f ... diff`). |
| ZFS pool health | `just ssh-root` then `zpool status` / `zfs list`. Read-only inspection is fine; **never** modify pools/datasets without confirmation. |

## Common playbooks

**Update flake inputs.** `just update [input]` bumps `flake.lock` — this is a
confirm-first action (AGENTS.md). After: `nix fmt`, `just eval`, then
`just boot` or `just dry` before a full deploy so a bad bump can't brick the
live activation. Keep the `flake.lock` bump as its own atomic change.

**Add / remove a service.** Walk the "New service checklist" in `AGENTS.md`
(Gatus probe, alerts, exposure, gallery tile, secrets, docs, symmetric
removal). Deploy per the safe change loop. Removing a service means also
deleting its Gatus endpoint (and bumping `checksum/config` in the gatus
Deployment), VMRules, ingress, gallery tile, secrets, and docs — dead probes
create alert noise, dead tiles make the gallery lie.

**App gallery tile (every public service).** `https://apps.rithviknishad.dev`
(Homepage, `k8s/homepage/`, deep dive in `docs/apps.md`) lists every public
service — including Access-gated ones. It auto-discovers tiles from
`gethomepage.dev/*` annotations on Ingresses, so a new public Ingress gets:
- `enabled: "true"`, `name`, `description`, `icon` (`mdi-*` or a
  dashboard-icons name), and an **explicit https `href`** — otherwise
  Homepage builds it from the first rule's host with `http://` (our Ingresses
  have no `tls:` block; TLS ends at Cloudflare).
- `group`: reuse an existing one (Personal, CARE, TeleICU, Infrastructure,
  Dev Tools) before inventing a new one.
- `weight`: **always set it.** Discovered tiles default to `0` and static
  ones to `(index+1)*100`, so without it ordering is arbitrary.
- `pod-selector`: the label selector for the status/CPU/RAM badge. It must
  exclude Job/CronJob pods (a finished Job shows the tile as down) — e.g.
  `app` ("has the label") where Jobs lack it, or `app in (a,b)`. Use `""` for
  no badge.
- Optional `widget.*` annotations; anything a widget calls must be reachable
  from the `homepage` namespace (add a NetworkPolicy like
  `allow-homepage-to-gatus` if the target namespace is default-deny).

Discovery makes **one tile per Ingress**, so extra hosts on a multi-host
Ingress (e.g. `care-api`, `care-teleicu-devices`) need a static entry in
`services.yaml` inside `k8s/homepage/homepage.yaml` **plus a
`checksum/config` bump** on the homepage Deployment (it only reads config at
startup). Static entries do NOT disappear when their Ingress is removed —
delete them by hand. Apply the service's own Ingress with `kubectl apply -k`
(annotations are picked up live, no homepage restart); apply gallery config
with `just apps-deploy`. Verify via the `/api/services` curl above.

Gallery troubleshooting: Traefik "no available server" + pod crash-looping
with `Failed to initialize required config ... EROFS` → a skeleton file is
missing from the ConfigMap (Homepage creates it lazily on e.g. the browser's
`/api/validate`, so `curl /` won't reproduce it; note a CrashLoopBackOff pod
still reports phase `Running` — check restarts/events, not just phase). Add
the key and bump `checksum/config`; re-diff against the image's
`/app/src/skeleton` on every Homepage upgrade. HTTP 400 "Host validation
failed" → the host isn't
in `HOMEPAGE_ALLOWED_HOSTS`; config edits not showing → missing
`checksum/config` bump; tiles listed but page empty/skeleton → the
`postStart` revalidate hook failed (`just apps-logs`). The
`EROFS ... prerender cache` warning at startup is **expected** (read-only
root; Next keeps the revalidated page in memory). Don't add the
`prometheusmetric` widget — it would proxy arbitrary PromQL to the public.

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
  is healthy; public services show up (correctly grouped) in the app gallery.
