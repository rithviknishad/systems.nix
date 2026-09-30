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

# Fetch the k3s kubeconfig to ~/.kube/avocado (server rewritten to avocado).
# Use it: export KUBECONFIG=~/.kube/avocado  (or load it into Lens).
kubeconfig:
    mkdir -p ~/.kube
    ssh {{NIX_SSHOPTS}} {{target}} 'cat /etc/rancher/k3s/k3s.yaml' \
        | sed 's/127.0.0.1/avocado/' > ~/.kube/avocado
    @echo "wrote ~/.kube/avocado — try: KUBECONFIG=~/.kube/avocado kubectl get nodes"

# --- Monitoring stack (VictoriaMetrics + Grafana + ntfy) --------------------
# All recipes below target the box via ~/.kube/avocado (run `just kubeconfig`
# once first). See k8s/monitoring/README.md for the full walkthrough.

kubeconfig_path := "~/.kube/avocado"

# Deploy/upgrade the monitoring stack: namespace + helm release + CR layer.
# The Grafana admin password is sops-decrypted from secrets/monitoring.enc.yaml
# into the gitignored values-secret.yaml just before `helmfile sync`.
mon-deploy:
    sops --decrypt secrets/monitoring.enc.yaml > k8s/monitoring/values-secret.yaml
    KUBECONFIG={{kubeconfig_path}} kubectl apply -f k8s/monitoring/namespace.yaml
    KUBECONFIG={{kubeconfig_path}} helmfile sync --file k8s/monitoring/helmfile.yaml
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/monitoring

# Show the state of the monitoring namespace (pods, services, rules).
mon-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n monitoring get pods,svc,ingress,vmrule

# Port-forward Grafana to http://localhost:3000 (admin / monitoring.enc.yaml password).
mon-grafana:
    KUBECONFIG={{kubeconfig_path}} kubectl -n monitoring port-forward svc/grafana 3000:3000

# Port-forward Gatus (uptime dashboard) to http://localhost:8080.
mon-gatus:
    KUBECONFIG={{kubeconfig_path}} kubectl -n monitoring port-forward svc/gatus 8080:8080

# Port-forward VictoriaLogs UI/API to http://localhost:9428 (try /select/vmui).
mon-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n monitoring port-forward svc/victorialogs 9428:9428

# Tail the ntfy bridge logs (shows alerts as they're pushed).
mon-ntfy-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n monitoring logs -f deploy/ntfy-alertmanager

# Print the latest speedtest results (runs a real test, ~30s, if cache expired).
mon-speedtest:
    # 127.0.0.1, not localhost: busybox wget tries ::1 first and the exporter
    # binds IPv4 only, which reads as a confusing "connection refused".
    KUBECONFIG={{kubeconfig_path}} kubectl -n monitoring exec deploy/speedtest-exporter -- \
        wget -qO- http://127.0.0.1:9798/metrics | grep '^speedtest_'

# Send a test push to an ntfy topic (default: avocado-alerts).
mon-ntfy-test topic="avocado-alerts":
    curl -H "Title: avocado monitoring test" -H "Tags: white_check_mark" \
        -d "ntfy wiring works" "https://ntfy.sh/{{topic}}"

# Remove the monitoring stack (CR layer + helm release). Keeps the namespace.
mon-destroy:
    -KUBECONFIG={{kubeconfig_path}} kubectl delete -k k8s/monitoring
    KUBECONFIG={{kubeconfig_path}} helmfile destroy --file k8s/monitoring/helmfile.yaml

# Edit the sops-encrypted monitoring secret (Grafana admin password, ntfy token).
mon-secrets:
    sops secrets/monitoring.enc.yaml

# Re-encrypt the monitoring secret after changing recipients in .sops.yaml.
mon-secrets-rekey:
    sops updatekeys secrets/monitoring.enc.yaml

# --- Storage / backup durability --------------------------------------------
# k3s's default `local-path` StorageClass uses reclaimPolicy: Delete, so
# deleting a namespace permanently destroys every volume in it. That is how
# the CARE database AND its 14 days of pg_dumps were lost on 2026-08-31.
# See k8s/storage/local-path-retain.yaml and docs/storage.md.

# Install the `local-path-retain` StorageClass (Retain reclaim policy) so that
# backup PVCs survive their namespace being deleted. Idempotent.
# Install the local-path-retain StorageClass (backup volumes survive ns delete)
storage-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/storage

# Retro-fit protection onto backup volumes that ALREADY exist. storageClassName
# is immutable on a live PVC, so an existing backup volume cannot simply be
# moved to local-path-retain — but the PV's reclaim policy CAN be patched in
# place, which buys the same protection without touching the data.
# Patch existing backup PVs to Retain so they outlive their namespace
backups-protect:
    #!/usr/bin/env sh
    set -eu
    export KUBECONFIG={{kubeconfig_path}}
    kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.claimRef.namespace}{" "}{.spec.claimRef.name}{" "}{.spec.persistentVolumeReclaimPolicy}{"\n"}{end}' \
    | while read -r pv ns claim policy; do
        case "$claim" in
          *-db-backups) ;;
          *) continue ;;
        esac
        if [ "$policy" = "Retain" ]; then
          echo "ok      $ns/$claim ($pv) already Retain"
        else
          kubectl patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
          echo "patched $ns/$claim ($pv) $policy -> Retain"
        fi
      done

# Show every backup volume, its reclaim policy, and the dumps it holds — the
# quickest way to answer "do I actually have a restorable backup right now?".
# Show backup volumes, reclaim policies, last CronJob success, and dumps on disk
backups-status:
    #!/usr/bin/env sh
    set -eu
    export KUBECONFIG={{kubeconfig_path}}
    # Capture once: piping the same stream into both `sed 1p` and `grep` would
    # let the first consumer swallow all of stdin.
    pvs="$(kubectl get pv -o custom-columns='PV:.metadata.name,NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,POLICY:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase')"
    echo "--- backup PVs (reclaim policy matters: Delete = dies with the namespace) ---"
    echo "$pvs" | sed -n 1p
    echo "$pvs" | grep -- '-db-backups' || echo '(none found)'
    echo
    cjs="$(kubectl get cronjob -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST_SUCCESS:.status.lastSuccessfulTime')"
    echo "--- backup CronJobs (last successful run) ---"
    echo "$cjs" | sed -n 1p
    echo "$cjs" | grep -- '-db-backup' || echo '(none found)'
    echo
    # The local-path storage dir is root-only, so list it over the same
    # passwordless root ssh path the deploy recipes use.
    echo "--- dumps on disk ---"
    ssh {{NIX_SSHOPTS}} {{target}} 'for d in /var/lib/rancher/k3s/storage/*-db-backups; do [ -d "$d" ] || continue; echo "$d:"; ls -lh "$d" | tail -n +2; echo; done' || echo '(could not read storage dir)'

# --- ESPHome (dashboard for ESP32/ESP8266 firmware) --------------------------
# Runs in k3s with hostNetwork (mDNS/OTA need the LAN). Dashboard:
#   http://avocado:6052 (Tailscale) or https://esphome.rithviknishad.dev
#   (Cloudflare Tunnel + Access). See docs/esphome.md.

# Deploy/upgrade ESPHome: manifests + secrets.yaml from sops (no temp file),
# then restart so the (subPath-mounted, non-live-updating) secret is picked up.
esphome-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/esphome
    sops --decrypt secrets/esphome.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl -n esphome create secret generic esphome-secrets \
            --from-file=secrets.yaml=/dev/stdin --dry-run=client -o yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -
    KUBECONFIG={{kubeconfig_path}} kubectl -n esphome rollout restart deploy/esphome

# Show the state of the esphome namespace.
esphome-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n esphome get pods,svc,ingress,pvc

# Tail the ESPHome dashboard logs.
esphome-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n esphome logs -f deploy/esphome

# Edit the sops-encrypted ESPHome secrets (WiFi creds etc.). Redeploy after.
esphome-secrets:
    sops secrets/esphome.enc.yaml

# Re-encrypt the ESPHome secret after changing recipients in .sops.yaml.
esphome-secrets-rekey:
    sops updatekeys secrets/esphome.enc.yaml

# --- Formance Ledger (standalone) --------------------------------------------
# Path A of the roadmap: Ledger + worker + Caddy gateway + Console UI + a
# dedicated Postgres, all in the `formance` namespace (k8s/formance). Console:
#   https://ledger.rithviknishad.dev  (Cloudflare Tunnel + Access)
#   http://avocado (Host: ledger.avocado.local) over Tailscale.
# See docs/formance.md.

# Deploy/upgrade Formance: manifests via kustomize, then the sops-encrypted
# k8s Secret piped straight into kubectl (plaintext never touches disk).
formance-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/formance
    sops --decrypt secrets/formance.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -

# Show the state of the formance namespace.
formance-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n formance get pods,svc,ingress,pvc

# Tail the ledger API server logs (use worker/gateway/console for the others).
formance-logs component="ledger":
    KUBECONFIG={{kubeconfig_path}} kubectl -n formance logs -f deploy/{{component}}

# Edit the sops-encrypted Formance secret (DB password, POSTGRES_URI,
# COOKIE_SECRET). After changing it, `rollout restart` the consumers to pick
# it up (env-from-secret pods don't auto-reload), then formance-deploy.
formance-secrets:
    sops secrets/formance.enc.yaml

# Re-encrypt the Formance secret after changing recipients in .sops.yaml.
formance-secrets-rekey:
    sops updatekeys secrets/formance.enc.yaml

# --- Kite (Kubernetes dashboard) ---------------------------------------------
# Full cluster-admin console on k3s (k8s/kite). Gated by its OWN GitHub OAuth
# (only the mapped GitHub user gets in), so no Cloudflare Access in front.
#   https://kite.rithviknishad.dev  (Cloudflare Tunnel + GitHub OAuth)
#   http://avocado (Host: kite.avocado.local) over Tailscale.
# See docs/kite.md.

# Deploy/upgrade Kite: kustomize manifests, then the sops-encrypted k8s Secret
# piped straight into kubectl (plaintext never touches disk). Ends with a
# rollout restart so the pod reloads the new secret and config.
kite-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/kite
    sops --decrypt secrets/kite.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -
    KUBECONFIG={{kubeconfig_path}} kubectl -n kite rollout restart deploy/kite

# Show the state of the kite namespace.
kite-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n kite get pods,svc,ingress,pvc

# Tail the Kite server logs.
kite-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n kite logs -f deploy/kite

# Edit the sops-encrypted Kite secret (JWT/encrypt keys, GitHub OAuth app,
# break-glass password). Redeploy after to apply.
kite-secrets:
    sops secrets/kite.enc.yaml

# Re-encrypt the Kite secret after changing recipients in .sops.yaml.
kite-secrets-rekey:
    sops updatekeys secrets/kite.enc.yaml

# --- Zerodha Kite MCP server (trading API for AI clients) ---------------------
# A Go MCP server (github:zerodha/kite-mcp-server) exposing the Kite Connect
# trading API. The image is built by Nix (pkgs/zerodha-kite, from the pinned
# `kite-mcp-server` flake input) and preloaded into k3s via services.k3s.images
# (modules/zerodha-kite.nix) during `just deploy` — no registry. Reached at
# http://avocado:30080 over the tailnet only (NodePort; see docs/zerodha-kite.md).
# Named "zerodha-kite" to avoid clashing with the Kite k8s dashboard above.

# Deploy/upgrade the Kite MCP server: kustomize manifests, then the
# sops-encrypted k8s Secret (KITE_API_KEY/SECRET) piped straight into kubectl
# (plaintext never touches disk). Ends with a rollout restart so the pod picks
# up the new secret/config. NOTE: the image lands on the box via `just deploy`
# (k3s preload), not here.
zerodha-kite-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/zerodha-kite
    sops --decrypt secrets/zerodha-kite.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -
    KUBECONFIG={{kubeconfig_path}} kubectl -n zerodha-kite rollout restart deploy/zerodha-kite

# Show the state of the zerodha-kite namespace.
zerodha-kite-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n zerodha-kite get pods,svc

# Tail the Kite MCP server logs.
zerodha-kite-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n zerodha-kite logs -f deploy/zerodha-kite

# Edit the sops-encrypted Kite MCP secret (KITE_API_KEY + KITE_API_SECRET of
# your Kite Connect app). Redeploy after to apply.
zerodha-kite-secrets:
    sops secrets/zerodha-kite.enc.yaml

# Re-encrypt the Kite MCP secret after changing recipients in .sops.yaml.
zerodha-kite-secrets-rekey:
    sops updatekeys secrets/zerodha-kite.enc.yaml

# --- Settle Up MCP server (shared expenses for AI clients) -------------------
# A FastMCP (Python) server from our own repo github:rithviknishad/settle-up-mcp
# exposing Settle Up groups/members/transactions/balances/recurring templates as
# 26 read AND write tools — including deletes (gated by a required `confirm`).
# Unlike zerodha-kite it is NOT Nix-built: the upstream repo publishes a
# multi-arch image to GHCR on every push to main, and the pod tracks `:latest`
# with imagePullPolicy: Always — so `settle-up-mcp-deploy` alone is the whole
# upgrade path (no `just deploy`, no flake input). Reached over the tailnet only
# at https://avocado.orthrus-bass.ts.net:10000/mcp (see docs/settle-up-mcp.md).

# Deploy/upgrade the Settle Up MCP server: kustomize manifests, then the
# sops-encrypted k8s Secret (Settle Up credentials + Firebase key + MCP bearer
# token) piped straight into kubectl (plaintext never touches disk). Ends with a
# rollout restart, which also re-pulls `:latest` — run this alone to pick up a
# new upstream build.
settle-up-mcp-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/settle-up-mcp
    sops --decrypt secrets/settle-up-mcp.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -
    KUBECONFIG={{kubeconfig_path}} kubectl -n settle-up-mcp rollout restart deploy/settle-up-mcp

# Show the state of the settle-up-mcp namespace.
settle-up-mcp-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n settle-up-mcp get pods,svc

# Tail the Settle Up MCP server logs.
settle-up-mcp-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n settle-up-mcp logs -f deploy/settle-up-mcp

# Edit the sops-encrypted Settle Up MCP secret (account email/password, live
# Firebase Web API key, MCP bearer token). Redeploy after to apply.
settle-up-mcp-secrets:
    sops secrets/settle-up-mcp.enc.yaml

# Re-encrypt the Settle Up MCP secret after changing recipients in .sops.yaml.
settle-up-mcp-secrets-rekey:
    sops updatekeys secrets/settle-up-mcp.enc.yaml

# --- Bingo (boardgame.io multiplayer party game) -----------------------------
# Single-origin app: server.cjs (Koa) serves the built SPA *and* the
# boardgame.io multiplayer API/websocket on :8000. The image is built by Nix
# (pkgs/bingo, from the pinned `bingo-app` flake input) and preloaded into k3s
# via services.k3s.images (modules/bingo.nix) during `just deploy` — no
# registry. Public at https://bingo.rithviknishad.dev. See docs/kubernetes.md.

# Deploy the bingo manifests (namespace, deployment, service, ingress).
# The image itself lands on the box via `just deploy` (k3s preload), not here.
bingo-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/bingo

# Show the state of the bingo namespace.
bingo-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n bingo get pods,svc,ingress

# Tail the bingo server logs.
bingo-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n bingo logs -f deploy/bingo

# Build the OCI image locally to inspect it (deploy preloads it into k3s for
# real; this is just for debugging the build).
bingo-image:
    nix build .#packages.x86_64-linux.bingo-image

# --- CARE (Open Healthcare Network HMIS + TeleICU) ---------------------------
# Two stacks: k8s/care (VersityGW + Postgres + Redis + Django API/celery + SPA
# + care-abdm MFE) and k8s/care-teleicu (gateway middleware + RTSPtoWeb +
# devices MFE + mock devices). Public hosts (flattened to one label —
# Cloudflare Universal SSL only covers *.rithviknishad.dev):
#   https://care.rithviknishad.dev                   ONE origin, path-routed:
#       /api/* -> backend, /mfe-plugs/abdm/* -> ABDM MFE,
#       /care-uploads/*, /care-facility/* -> VersityGW, /* -> SPA
#   https://care-api.rithviknishad.dev               Django API (TeleICU, admin)
#   https://care-teleicu-gateway.rithviknishad.dev   TeleICU gateway
#   https://care-teleicu-devices.rithviknishad.dev   devices micro-frontend
#   https://mock-ptz-camera.rithviknishad.dev        mock camera web UI (admin/admin)
# Custom images are built ON the box with docker (modules/docker.nix) and
# imported straight into k3s's containerd — no registry. See docs/care.md.

care_build := ".build"
care_origin := "https://care.rithviknishad.dev"

# Backend image only. Split out of care-images because the two repos have
# independent branches: a backend feature branch (e.g. ENG-998) usually has no
# counterpart in care_fe, so building both from one ref would fail on the SPA
# clone. `repo` allows forks. care-backend:local bakes the plugs in at build
# time (upstream pip-installs ADDITIONAL_PLUGS in the Dockerfile). The tag is
# shared, so this overwrites whatever ref was built last — roll back by
# rebuilding from develop. Restart the three consumers afterwards to pick the
# new image up:
#   just care-backend-image rithviknishad/bodhi/ENG-737-test-fixtures rithviknishad/care
#   kubectl -n care rollout restart deploy/care-backend deploy/care-celery-worker deploy/care-celery-beat
care-backend-image ref="develop" repo="ohcnetwork/care":
    rm -rf {{care_build}}/care
    mkdir -p {{care_build}}
    git clone --depth 1 --branch {{ref}} https://github.com/{{repo}} {{care_build}}/care
    docker build -t care-backend:local \
        --build-arg ADDITIONAL_PLUGS="$(cat k8s/care/additional-plugs.json)" \
        -f {{care_build}}/care/docker/prod.Dockerfile {{care_build}}/care
    docker save care-backend:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# SPA image only. The API URL is compiled into the bundle (.env.local beats
# the repo's .env for Vite): it is the app's own origin, since /api is
# path-routed on it. REACT_MFE_REGISTERED_COMPONENTS names every core
# component a plug may override — AddFacilitySheet is care-abdm's; a plug
# overriding an unlisted component silently gets no override. Then:
#   kubectl -n care rollout restart deploy/care-fe
care-fe-image ref="develop" repo="ohcnetwork/care_fe":
    rm -rf {{care_build}}/care_fe
    mkdir -p {{care_build}}
    git clone --depth 1 --branch {{ref}} https://github.com/{{repo}} {{care_build}}/care_fe
    printf 'REACT_CARE_API_URL={{care_origin}}\nREACT_MFE_REGISTERED_COMPONENTS=AddFacilitySheet\n' \
        > {{care_build}}/care_fe/.env.local
    docker build -t care-fe:local {{care_build}}/care_fe
    docker save care-fe:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# ABDM plug frontend (module-federation remote), from k8s/care/abdm-fe/. The
# commit is read from the abdm entry in k8s/care/additional-plugs.json so the
# FE and BE halves of the plug are always the same revision; bump it there.
#   kubectl -n care rollout restart deploy/care-abdm-fe
care-abdm-fe-image:
    docker build -t care-abdm-fe:local \
        --build-arg CARE_ABDM_REF="$(python3 -c 'import json; print(next(p for p in json.load(open("k8s/care/additional-plugs.json")) if p["name"] == "abdm")["package_name"].split("@")[1].split("#")[0])')" \
        k8s/care/abdm-fe
    docker save care-abdm-fe:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# Build + import all core images. Both refs default to develop; the repos'
# branches are independent, so pass each explicitly for feature work. Import
# goes through root ssh (same passwordless path as `just deploy`) because
# k3s ctr needs root.
care-images be_ref="develop" fe_ref="develop" be_repo="ohcnetwork/care" fe_repo="ohcnetwork/care_fe": (care-backend-image be_ref be_repo) (care-fe-image fe_ref fe_repo) care-abdm-fe-image

# Build + import the TeleICU custom images (devices MFE + mock PTZ camera).
# The gateway itself uses published ghcr.io/10bedicu images — no build needed.
care-teleicu-images:
    rm -rf {{care_build}}/care_teleicu_devices_fe {{care_build}}/mock-ptz-camera
    mkdir -p {{care_build}}
    git clone --depth 1 https://github.com/10bedicu/care_teleicu_devices_fe {{care_build}}/care_teleicu_devices_fe
    docker build -t care-teleicu-devices-fe:local {{care_build}}/care_teleicu_devices_fe
    git clone --depth 1 https://github.com/10bedicu/mock-ptz-camera {{care_build}}/mock-ptz-camera
    docker build -t mock-ptz-camera:local {{care_build}}/mock-ptz-camera
    docker save care-teleicu-devices-fe:local mock-ptz-camera:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# Deploy/upgrade the core care stack: manifests via kustomize, then the
# sops-encrypted Secret piped straight into kubectl (plaintext never touches
# disk). Secret changes need a rollout restart of the consumers to be seen.
care-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/care
    sops --decrypt secrets/care.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -

# Deploy/upgrade the TeleICU stack (same pattern as care-deploy).
care-teleicu-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/care-teleicu
    sops --decrypt secrets/care-teleicu.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -

# Show the state of both care namespaces.
care-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n care get pods,svc,ingress,pvc,jobs,cronjobs
    KUBECONFIG={{kubeconfig_path}} kubectl -n care-teleicu get pods,svc,ingress,pvc,cronjobs

# Tail a care component's logs (care-backend, care-celery-worker,
# care-celery-beat, care-fe, care-abdm-fe, postgres, redis, versitygw).
care-logs component="care-backend":
    KUBECONFIG={{kubeconfig_path}} kubectl -n care logs -f deploy/{{component}}

# Tail a TeleICU component's logs (teleicu-middleware, teleicu-celery,
# stream-server, reverse-proxy, teleicu-devices-fe, mock-ptz-camera,
# mock-vitals-hl7, mock-vitals-ventilator, postgres, redis).
care-teleicu-logs component="teleicu-middleware":
    KUBECONFIG={{kubeconfig_path}} kubectl -n care-teleicu logs -f deploy/{{component}}

# Run a manage.py command in the care backend (e.g. `just care-manage
# createsuperuser`, `just care-manage load_fixtures`).
care-manage *args:
    KUBECONFIG={{kubeconfig_path}} kubectl -n care exec -it deploy/care-backend -- python manage.py {{args}}

# Register (or update) a CARE micro-frontend plug via the plug_config API, so
# the SPA loads its remoteEntry.js on next load. No UI clicks needed.
# Idempotent (PUT if the slug exists, else POST). `meta` is the plug's JSON
# meta object (no single quotes). Needs an admin (is_staff) login — defaults
# to the load_fixtures admin/admin, so pass real creds once that's rotated.
care-register-plug slug meta user="admin" pass="admin":
    #!/usr/bin/env sh
    set -eu
    api={{care_origin}}
    token=$(curl -fsS -X POST "$api/api/v1/auth/login/" -H 'Content-Type: application/json' \
        -d '{"username":"{{user}}","password":"{{pass}}"}' \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access'])")
    body=$(python3 -c 'import json,sys; print(json.dumps({"slug": sys.argv[1], "meta": json.loads(sys.argv[2])}))' '{{slug}}' '{{meta}}')
    if curl -fs -o /dev/null "$api/api/v1/plug_config/{{slug}}/" -H "Authorization: Bearer $token"; then
        curl -fsS -X PUT "$api/api/v1/plug_config/{{slug}}/" -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' -d "$body" >/dev/null
        echo "updated plug_config: {{slug}}"
    else
        curl -fsS -X POST "$api/api/v1/plug_config/" -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' -d "$body" >/dev/null
        echo "created plug_config: {{slug}}"
    fi

# The TeleICU devices MFE (served from its own host, k8s/care-teleicu):
#   just care-register-mfe myadmin 's3cr3t'
care-register-mfe user="admin" pass="admin": (care-register-plug "teleicu-devices" '{"url":"https://care-teleicu-devices.rithviknishad.dev/assets/remoteEntry.js","name":"CARE TeleICU Devices","plug":"teleicu-devices"}' user pass)

# The care-abdm MFE (same origin, /mfe-plugs/abdm). `name` must be the
# federation name from the plug's vite.config.ts.
care-register-abdm user="admin" pass="admin": (care-register-plug "abdm" '{"url":"https://care.rithviknishad.dev/mfe-plugs/abdm/assets/remoteEntry.js","localPath":"/mfe-plugs/abdm","name":"care_abdm_fe","plug":"abdm"}' user pass)

# Load CARE's demo fixtures (default_fixtures.py: facilities, org tree, demo
# users incl. admin/admin). Faker is a dev-only dependency, so it's pip-
# installed into the running pod first (ephemeral: gone on the next restart,
# which is fine). load_fixtures refuses to run when IS_PRODUCTION is set;
# config.settings.deployment leaves it False. Run on an EMPTY, migrated DB
# (see care-db-reset), then rotate the admin password. The fixture context
# also refuses unless settings.DEBUG, so DJANGO_DEBUG is set for this one
# process only — the serving pods keep DEBUG off.
care-seed-demo:
    KUBECONFIG={{kubeconfig_path}} kubectl -n care exec deploy/care-backend -- \
        sh -c 'pip install -q Faker==38.2.0 && DJANGO_DEBUG=true python manage.py load_fixtures'

# Take an on-demand dump into the backups PVC under pinned/ (the nightly
# prune only touches the top level, so pinned dumps are kept until deleted by
# hand). Prints the TOC size + sha256 as a quick integrity check.
#   just care-db-pin before-upgrade
care-db-pin tag=("manual-" + datetime("%Y%m%d-%H%M%S")):
    #!/usr/bin/env sh
    set -eu
    k() { KUBECONFIG={{kubeconfig_path}} kubectl -n care "$@"; }
    job=care-db-pin-$(date +%s)
    k create -f - <<EOF
    apiVersion: batch/v1
    kind: Job
    metadata: { name: $job }
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 3600
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: pin
              image: postgres:17-alpine
              envFrom: [{ secretRef: { name: care-secret } }]
              command:
                - sh
                - -c
                - |
                  set -eu
                  f=/backups/pinned/care-{{tag}}.dump
                  mkdir -p /backups/pinned
                  pg_dump "\$DATABASE_URL" -Fc -f "\$f"
                  echo "TOC entries: \$(pg_restore --list "\$f" | grep -vc '^;')"
                  sha256sum "\$f"; ls -lh /backups/pinned
              volumeMounts: [{ name: backups, mountPath: /backups }]
          volumes:
            - { name: backups, persistentVolumeClaim: { claimName: care-db-backups } }
    EOF
    until [ -n "$(k get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}')" ]; do sleep 2; done
    k logs "job/$job"
    [ "$(k get job "$job" -o jsonpath='{.status.succeeded}')" = 1 ]

# DESTRUCTIVE: wipe the care DB to empty (pins a dump first), flush Redis,
# then bring the backend back so celery-beat re-runs every migration from
# scratch. Seed afterwards with `just care-seed-demo`. Does NOT touch
# VersityGW objects (orphaned uploads are harmless) or the TeleICU stack.
[confirm("Pin a dump, then DROP the care database and flush Redis?")]
care-db-reset: (care-db-pin ("pre-reset-" + datetime("%Y%m%d-%H%M%S")))
    #!/usr/bin/env sh
    set -eu
    k() { KUBECONFIG={{kubeconfig_path}} kubectl -n care "$@"; }
    k scale --replicas=0 deploy/care-backend deploy/care-celery-worker deploy/care-celery-beat
    k wait --for=delete pod -l 'app in (care-backend,care-celery-worker,care-celery-beat)' --timeout=120s || true
    k exec deploy/postgres -- sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE)" \
        -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\""'
    k exec deploy/redis -- redis-cli FLUSHALL
    k scale --replicas=1 deploy/care-backend deploy/care-celery-worker deploy/care-celery-beat
    echo "DB reset; watch migrations with: just care-logs care-celery-beat"

# DESTRUCTIVE: replace the care DB with a dump from the backups PVC (path
# relative to it, e.g. pinned/care-pre-abdm-reset-2026-09-29.dump or
# care-2026-09-28.dump). Pins the current state first. Beat migrates forward
# on start if the dump predates the running code; restoring a dump NEWER than
# the code (unknown migrations) is not supported — rebuild the matching image.
[confirm("Pin a dump, then REPLACE the care database with the given dump?")]
care-db-restore file: (care-db-pin ("pre-restore-" + datetime("%Y%m%d-%H%M%S")))
    #!/usr/bin/env sh
    set -eu
    k() { KUBECONFIG={{kubeconfig_path}} kubectl -n care "$@"; }
    k scale --replicas=0 deploy/care-backend deploy/care-celery-worker deploy/care-celery-beat
    k wait --for=delete pod -l 'app in (care-backend,care-celery-worker,care-celery-beat)' --timeout=120s || true
    k exec deploy/postgres -- sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE)" \
        -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\""'
    job=care-db-restore-$(date +%s)
    k create -f - <<EOF
    apiVersion: batch/v1
    kind: Job
    metadata: { name: $job }
    spec:
      backoffLimit: 0
      ttlSecondsAfterFinished: 3600
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: restore
              image: postgres:17-alpine
              envFrom: [{ secretRef: { name: care-secret } }]
              command: [sh, -c, 'pg_restore --no-owner --exit-on-error -d "\$DATABASE_URL" "/backups/{{file}}"']
              volumeMounts: [{ name: backups, mountPath: /backups, readOnly: true }]
          volumes:
            - { name: backups, persistentVolumeClaim: { claimName: care-db-backups } }
    EOF
    until [ -n "$(k get job "$job" -o jsonpath='{.status.succeeded}{.status.failed}')" ]; do sleep 2; done
    k logs "job/$job"
    [ "$(k get job "$job" -o jsonpath='{.status.succeeded}')" = 1 ]
    k exec deploy/redis -- redis-cli FLUSHALL
    k scale --replicas=1 deploy/care-backend deploy/care-celery-worker deploy/care-celery-beat
    echo "restored {{file}}; watch: just care-logs care-celery-beat"

# Register an ONVIF camera's RTSP feed with the in-cluster RTSPtoWeb and print
# its stream_id — the value to put in the CARE camera device's `stream_id`
# (the device itself is a separate POST /device/ call, see docs/care.md).
# Runs scripts/register-camera-stream.py inside the middleware pod (has
# onvif-zeep). onvif_port is 80 for real cameras, 8080 for the mock. Pass a
# stream_id as the last arg to re-register the SAME id.
# NOTE: this writes the stream to RTSPtoWeb's API at RUNTIME, so it's lost on a
# stream-server/node restart. For a camera that should PERSIST, make it
# declarative instead with `just care-resolve-camera` (below):
#   just care-register-camera 192.168.1.50 admin 's3cr3t'
care-register-camera ip user pass profile="0" onvif_port="80" stream_id="":
    KUBECONFIG={{kubeconfig_path}} kubectl -n care-teleicu exec -i deploy/teleicu-middleware -- \
        python - '{{ip}}' '{{user}}' '{{pass}}' '{{profile}}' '{{onvif_port}}' '{{stream_id}}' \
        < k8s/care-teleicu/scripts/register-camera-stream.py

# Resolve a camera's RTSP URL over ONVIF and print a RTSPtoWeb `streams`
# fragment (keyed by stream_id) for DECLARATIVE persistence. Paste/merge the
# output under "streams" in RTSPTOWEB_CONFIG_JSON via `just care-teleicu-secrets`,
# then `just care-teleicu-deploy` + `kubectl -n care-teleicu rollout restart
# deploy/stream-server`. The stream_id MUST match the CARE device's stream_id
# (read it from the device detail API). onvif_port is 80 for real cameras, 8080
# for the mock. See docs/care.md "Declarative camera streams":
#   just care-resolve-camera 192.168.1.50 admin 's3cr3t' <stream-id>
care-resolve-camera ip user pass stream_id profile="0" onvif_port="80":
    KUBECONFIG={{kubeconfig_path}} kubectl -n care-teleicu exec -i deploy/teleicu-middleware -- \
        python - '{{ip}}' '{{user}}' '{{pass}}' '{{stream_id}}' '{{profile}}' '{{onvif_port}}' \
        < k8s/care-teleicu/scripts/resolve-camera-stream.py

# (Re)create the TeleICU devices (gateway + one camera per persisted RTSPtoWeb
# stream + the mock HL7 monitor) on a CARE facility — run after every
# care-db-reset/restore that loses them. Idempotent (PUTs existing devices by
# registered_name). Camera host/creds come from the sops stream config and
# are never printed. Prints the new GATEWAY_DEVICE_ID to put in
# k8s/care-teleicu/care-teleicu.yaml (then care-teleicu-deploy + restart the
# middleware). Defaults to the load_fixtures admin; pass real creds later:
#   just care-wire-devices <facility-uuid> myadmin 's3cr3t'
care-wire-devices facility user="admin" pass="admin":
    sops --decrypt --output-type json secrets/care-teleicu.enc.yaml | \
        python3 k8s/care-teleicu/scripts/wire-devices.py '{{facility}}' '{{user}}' '{{pass}}'

# Edit the sops-encrypted care secret (see k8s/care/secret.example.yaml).
care-secrets:
    sops secrets/care.enc.yaml

care-secrets-rekey:
    sops updatekeys secrets/care.enc.yaml

# Edit the sops-encrypted TeleICU secret (see k8s/care-teleicu/secret.example.yaml).
care-teleicu-secrets:
    sops secrets/care-teleicu.enc.yaml

care-teleicu-secrets-rekey:
    sops updatekeys secrets/care-teleicu.enc.yaml

# One-time: point the public care hostnames at the tunnel. Needs the
# cloudflared login cert (cloudflared tunnel login) on this machine.
care-dns:
    for h in care care-api care-teleicu-gateway care-teleicu-devices mock-ptz-camera; do \
        cloudflared tunnel route dns avocado "$h.rithviknishad.dev"; done

# --- Onam Pookalam Vote (rithviknishad/ohc-pookalam) -------------------------
# A small GitHub-username-gated voting site for the OHC Network (Next.js 16 +
# SQLite). Public at https://ohc-pookalam.rithviknishad.dev, on the tailnet via
# Host: ohc-pookalam.avocado.local. The upstream repo ships its own Dockerfile
# (standalone Next build + native better-sqlite3), so the image is built ON the
# box with docker and imported into k3s's containerd — no registry, same
# pattern as the care images above. See docs/ohc-pookalam.md.

# Clone-then-build (not a flake input) because the Dockerfile does a pnpm
# install plus a node-gyp compile of better-sqlite3 that isn't worth nixifying.
# Uses the same .build/ scratch dir as the care image recipes. Import goes
# through root ssh (same passwordless path as `just deploy`) — k3s ctr needs
# root. Re-run to ship new upstream code, then `just ohc-pookalam-deploy`.
# Build + import the app image (defaults to the master branch).
ohc-pookalam-images ref="master":
    rm -rf .build/ohc-pookalam
    mkdir -p .build
    git clone --depth 1 --branch {{ref}} https://github.com/rithviknishad/ohc-pookalam .build/ohc-pookalam
    docker build -t ohc-pookalam:local .build/ohc-pookalam
    docker save ohc-pookalam:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# The sops-encrypted Secret is piped straight into kubectl (plaintext never
# touches disk). Ends with a rollout restart so a freshly imported image or a
# changed secret is actually picked up.
# Deploy/upgrade the pookalam site: kustomize + sops Secret + rollout restart.
ohc-pookalam-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/ohc-pookalam
    # The Secret is optional by design (envFrom sets optional: true), so a
    # first deploy without a PAT still works — skip it if it isn't there yet.
    if [ -f secrets/ohc-pookalam.enc.yaml ]; then sops --decrypt secrets/ohc-pookalam.enc.yaml | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -; else echo "note: secrets/ohc-pookalam.enc.yaml missing — running on the anonymous GitHub API rate limit (60/h)"; fi
    KUBECONFIG={{kubeconfig_path}} kubectl -n ohc-pookalam rollout restart deploy/ohc-pookalam

# Show the state of the ohc-pookalam namespace.
ohc-pookalam-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ohc-pookalam get pods,svc,ingress,pvc

# Tail the app logs.
ohc-pookalam-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ohc-pookalam logs -f deploy/ohc-pookalam

# The votes are the ONLY state here and the PVC sits on the no-redundancy ZFS
# stripe — run this before any risky change, and after the vote closes. Tars
# all of /data: the .db file alone can miss votes still in the -wal.
# Copy the SQLite database out of the pod (votes backup).
ohc-pookalam-backup dest="pookalam-backup":
    mkdir -p {{dest}}
    KUBECONFIG={{kubeconfig_path}} kubectl -n ohc-pookalam exec deploy/ohc-pookalam -- \
        tar cf - -C /data . > {{dest}}/pookalam-data.tar
    @echo "wrote {{dest}}/pookalam-data.tar"

# GITHUB_TOKEN — a scope-less PAT that lifts the api.github.com username-lookup
# rate limit from 60/h to 5000/h. Redeploy after to apply.
# Edit the sops-encrypted pookalam secret.
ohc-pookalam-secrets:
    sops secrets/ohc-pookalam.enc.yaml

# Re-encrypt the secret after changing recipients in .sops.yaml.
ohc-pookalam-secrets-rekey:
    sops updatekeys secrets/ohc-pookalam.enc.yaml

# Needs the cloudflared login cert (cloudflared tunnel login) on this machine.
# One-time: point the public hostname at the tunnel.
ohc-pookalam-dns:
    cloudflared tunnel route dns avocado ohc-pookalam.rithviknishad.dev

# --- ONVIF Camera Testing Console (10bedicu/onvif-console) --------------------
# Vendor-neutral ONVIF PTZ testing console (k8s/onvif-console). Public host is
# Access-gated (no auth of its own; relays camera credentials). See
# docs/onvif-console.md.

# Build + import the console image (Next UI + FastAPI sidecar, one image).
# Same no-registry pattern as care-images: docker build on the box, then pipe
# `docker save` into k3s's containerd over root ssh.
#
# The `packageManager` pin is load-bearing: upstream's package.json has no pin,
# so corepack pulls the latest pnpm (11.x), which makes an *ignored build
# script* (sharp) a FATAL error and breaks the Dockerfile's `pnpm install`.
# pnpm 9 only warns, and reads the repo's lockfileVersion 9.0 natively. The
# Dockerfile copies only package.json + the lockfile before install, so the pin
# has to live in package.json (a pnpm-workspace.yaml would not be copied).
onvif-console-images ref="main":
    rm -rf {{care_build}}/onvif-console
    mkdir -p {{care_build}}
    git clone --depth 1 --branch {{ref}} https://github.com/10bedicu/onvif-console {{care_build}}/onvif-console
    python3 -c "import json,pathlib; p=pathlib.Path('{{care_build}}/onvif-console/package.json'); d=json.loads(p.read_text()); d['packageManager']='pnpm@9.15.9'; p.write_text(json.dumps(d,indent=2)+chr(10))"
    docker build -t onvif-console:local {{care_build}}/onvif-console
    docker save onvif-console:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# Deploy/upgrade the console (kustomize apply). The public host only goes live
# once the Cloudflare Access app + tunnel DNS route exist (see docs).
onvif-console-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/onvif-console

# Show the state of the onvif-console namespace.
onvif-console-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n onvif-console get pods,svc,ingress

# Tail the console logs.
onvif-console-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n onvif-console logs -f deploy/onvif-console

# --- Open Terminology Server (ohcnetwork/open-healthcare-terminology-server) --
# FHIR-ish terminology API (Postgres + pgvector), single image run as api +
# celery worker (k8s/ots). Public host is app-key gated (x-api-key), no Access
# gate. CPU FastEmbed (bge-small-en-v1.5) for vector search.
#   https://ots.rithviknishad.dev/docs        Swagger (public path)
#   http://avocado (Host: ots.avocado.local)  over Tailscale
#   http://ots-api.ots:8000                   in-cluster (CARE), send x-api-key
# See docs/ots.md.

ots_build := ".build"

# Build + import the OTS image. Same no-registry pattern as care-images:
# docker build on this machine, then pipe `docker save` into k3s's containerd
# over root ssh. Pass a git ref to pin (defaults to main).
ots-images ref="main":
    rm -rf {{ots_build}}/ots
    mkdir -p {{ots_build}}
    git clone --depth 1 --branch {{ref}} https://github.com/ohcnetwork/open-healthcare-terminology-server {{ots_build}}/ots
    docker build -t open-terminology-server:local {{ots_build}}/ots
    docker save open-terminology-server:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

# Deploy/upgrade OTS: manifests via kustomize, then the sops-encrypted Secret
# piped straight into kubectl (plaintext never touches disk). Secret changes
# need a rollout restart of the consumers to be seen.
ots-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/ots
    sops --decrypt secrets/ots.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -

# Show the state of the ots namespace.
ots-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ots get pods,svc,ingress,pvc

# Tail an OTS component's logs (ots-api, ots-worker, postgres).
ots-logs component="ots-api":
    KUBECONFIG={{kubeconfig_path}} kubectl -n ots logs -f deploy/{{component}}

# Run the OTS CLI inside the api pod (e.g. `just ots-cli icd download`,
# `just ots-cli common embed -- --help`). See docs/ots.md "Loading data".
ots-cli *args:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ots exec -it deploy/ots-api -- python -m ots.cli {{args}}

# Edit the sops-encrypted OTS secret (see k8s/ots/secret.example.yaml).
ots-secrets:
    sops secrets/ots.enc.yaml

ots-secrets-rekey:
    sops updatekeys secrets/ots.enc.yaml

# One-time: point the public OTS hostname at the tunnel. Needs the cloudflared
# login cert (cloudflared tunnel login) on this machine.
ots-dns:
    cloudflared tunnel route dns avocado ots.rithviknishad.dev

# --- Attic (self-hostable Nix binary cache) ----------------------------------
# A single `atticd` (API + GC) backed by SQLite + a local NAR/chunk store on one
# PVC. Public image (ghcr.io/zhaofengli/attic), so no build-on-box step. Gated
# by JWT tokens minted with atticadm. NOT exposed publicly — reach it only over
# Tailscale/LAN at http://avocado (Host: attic.avocado.local). See docs/attic.md.

# Deploy/upgrade Attic: kustomize manifests, then the sops-encrypted Secret
# piped straight into kubectl (plaintext never touches disk). A secret change
# needs a rollout restart of atticd to be seen.
attic-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/attic
    sops --decrypt secrets/attic.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -

# Show the state of the attic namespace.
attic-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n attic get pods,svc,ingress,pvc

# Tail the atticd logs.
attic-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n attic logs -f deploy/atticd

# Mint an access token with atticadm inside the pod (it reads the same HS256
# secret from the env; -f points it at the mounted config). `sub` names the
# token holder; this grants full rights on all caches — narrow the globs for
# least privilege. e.g. `just attic-token laptop`. Copy the printed token into
# `attic login`.
attic-token sub validity="1y":
    KUBECONFIG={{kubeconfig_path}} kubectl -n attic exec deploy/atticd -- \
        atticadm make-token -f /attic/server.toml --sub {{sub}} --validity {{validity}} \
        --pull '*' --push '*' --create-cache '*' --configure-cache '*' \
        --configure-cache-retention '*' --destroy-cache '*' --delete '*'

# Edit the sops-encrypted Attic secret (the HS256 signing key). Redeploy after.
attic-secrets:
    sops secrets/attic.enc.yaml

attic-secrets-rekey:
    sops updatekeys secrets/attic.enc.yaml

# --- ntfy (self-hosted push notification server) -----------------------------
# One `ntfy serve` process: message cache, user/ACL/token DB and attachments all
# live on a single PVC (SQLite, no separate database). Public image, so no
# build-on-box step. Everything is gated by ntfy's own auth
# (auth-default-access: deny-all) rather than Cloudflare Access, because the
# publishers are token-holding scripts. Users/ACLs/tokens are declared in the
# sops secret and applied at startup.
#   https://ntfy.rithviknishad.dev             web app / PWA, public
#   http://avocado (Host: ntfy.avocado.local)  over Tailscale / LAN
#   http://ntfy.ntfy.svc:8080                  in-cluster
# See docs/ntfy.md.

# The NTFY_AUTH_* entries are only read at process start, so a secret change
# needs the rollout restart at the end.
# Deploy/upgrade ntfy: kustomize manifests + sops Secret + rollout restart.
ntfy-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/ntfy
    sops --decrypt secrets/ntfy.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -
    KUBECONFIG={{kubeconfig_path}} kubectl -n ntfy rollout restart deploy/ntfy

# Show the state of the ntfy namespace.
ntfy-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ntfy get pods,svc,ingress,pvc

# Tail the ntfy server logs (JSON).
ntfy-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ntfy logs -f deploy/ntfy

# Use it for the few things that aren't declarative:
#   just ntfy-cli user list          -> what's actually in user.db
#   just ntfy-cli access             -> the effective ACL table
#   just ntfy-cli user del <name>    -> removing from the secret does NOT delete
# Run the ntfy CLI inside the running pod.
ntfy-cli *args:
    KUBECONFIG={{kubeconfig_path}} kubectl -n ntfy exec -it deploy/ntfy -- ntfy {{args}}

# No running server needed, so this works before the first deploy. Both
# subcommands are offline — nothing is written anywhere:
#   just ntfy-gen user hash          -> bcrypt hash for NTFY_AUTH_USERS
#   just ntfy-gen token generate     -> tk_... for NTFY_AUTH_TOKENS
# Run the ntfy CLI in a THROWAWAY pod (to bootstrap the secret).
ntfy-gen *args:
    KUBECONFIG={{kubeconfig_path}} kubectl run ntfy-gen --rm -it --restart=Never \
        --image=binwiederhier/ntfy:v2.27.0 -- {{args}}

# The token is passed as an argument, so it lands in your shell history — use a
# throwaway/narrow one. It must have write access to the topic.
# Publish a test message over the public edge (proves auth + delivery).
ntfy-test topic token message="hello from just":
    curl -sS -H "Authorization: Bearer {{token}}" -d '{{message}}' \
        https://ntfy.rithviknishad.dev/{{topic}}

# See k8s/ntfy/secret.example.yaml for the format. Redeploy after to apply.
# Edit the sops-encrypted ntfy secret (NTFY_AUTH_USERS / _ACCESS / _TOKENS).
ntfy-secrets:
    sops secrets/ntfy.enc.yaml

# Re-encrypt the ntfy secret after changing recipients in .sops.yaml.
ntfy-secrets-rekey:
    sops updatekeys secrets/ntfy.enc.yaml

# Needs the cloudflared login cert (cloudflared tunnel login) on this machine.
# One-time: point the public ntfy hostname at the tunnel.
ntfy-dns:
    cloudflared tunnel route dns avocado ntfy.rithviknishad.dev

# --- SigNoz (OpenTelemetry APM: traces + logs + metrics) ---------------------
# ClickHouse + Zookeeper + the SigNoz query service + an OTel collector, from
# the upstream helm chart (k8s/signoz). This is the APPLICATION observability
# stack; k8s/monitoring (VictoriaMetrics/Grafana/Vector) still owns host and
# cluster infrastructure telemetry. Not exposed publicly — reach the UI only
# over Tailscale at http://avocado (Host: signoz.avocado.local), or with
# `just signoz-ui`. Apps send OTLP to signoz-otel-collector.signoz.svc:4317
# (gRPC) / :4318 (HTTP). See docs/signoz.md.

# The ClickHouse password is sops-decrypted from secrets/signoz.enc.yaml into
# the gitignored values-secret.yaml just before `helmfile sync` (the monitoring
# stack does the same thing — helm needs a file, not a stream). First run pulls
# ~2GB of images and migrates the ClickHouse schema; the helmfile timeout is
# 20min for that reason.
# Deploy/upgrade SigNoz: namespace + helm release + ingress layer.
signoz-deploy:
    sops --decrypt secrets/signoz.enc.yaml > k8s/signoz/values-secret.yaml
    KUBECONFIG={{kubeconfig_path}} kubectl apply -f k8s/signoz/namespace.yaml
    KUBECONFIG={{kubeconfig_path}} helmfile sync --file k8s/signoz/helmfile.yaml
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/signoz

# Show the state of the signoz namespace (pods, services, ingress, volumes).
signoz-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n signoz get pods,svc,ingress,pvc

# 3301 is SigNoz's own conventional port, kept so muscle memory works.
# Port-forward the SigNoz UI to http://localhost:3301 (no tailnet DNS needed).
signoz-ui:
    KUBECONFIG={{kubeconfig_path}} kubectl -n signoz port-forward svc/signoz 3301:8080

# Tail the query service logs (the first place to look for UI/query errors).
signoz-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n signoz logs -f deploy/signoz

# Where dropped/rejected spans show up when an instrumented app says it
# exported but nothing lands in the UI.
# Tail the OTel collector (ingest) logs.
signoz-collector-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n signoz logs -f deploy/signoz-otel-collector

# For checking table sizes/TTLs when the volume grows, e.g.
#   SELECT table, formatReadableSize(sum(bytes)) FROM system.parts
#     WHERE active GROUP BY table ORDER BY sum(bytes) DESC;
# The pod name is generated by the Altinity operator
# (chi-<chi>-<cluster>-<shard>-<replica>-0), so resolve it by label rather than
# hardcoding a name that a chart bump could change.
# Open a clickhouse-client shell inside the ClickHouse pod.
signoz-clickhouse:
    #!/usr/bin/env sh
    set -eu
    export KUBECONFIG={{ kubeconfig_path }}
    pod=$(kubectl -n signoz get pod -l clickhouse.altinity.com/chi=signoz-clickhouse \
        -o jsonpath='{.items[0].metadata.name}')
    exec kubectl -n signoz exec -it "$pod" -- clickhouse-client

# Edit the sops-encrypted SigNoz secret (the ClickHouse password). Redeploy after.
signoz-secrets:
    sops secrets/signoz.enc.yaml

# Re-encrypt the SigNoz secret after changing recipients in .sops.yaml.
signoz-secrets-rekey:
    sops updatekeys secrets/signoz.enc.yaml

# DESTRUCTIVE: the namespace's PVCs use `local-path` (reclaimPolicy Delete), so
# the ClickHouse telemetry history and the SigNoz dashboard/alert SQLite DB go
# with it. Keeps the namespace itself. Confirm with the operator before running.
# Remove the SigNoz helm release + ingress layer (DESTROYS the telemetry data).
signoz-destroy:
    -KUBECONFIG={{kubeconfig_path}} kubectl delete -k k8s/signoz
    KUBECONFIG={{kubeconfig_path}} helmfile destroy --file k8s/signoz/helmfile.yaml
