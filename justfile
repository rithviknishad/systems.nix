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
# Two stacks: k8s/care (MinIO + Postgres + Redis + Django API/celery + SPA)
# and k8s/care-teleicu (gateway middleware + RTSPtoWeb + devices MFE + mock
# devices). Public hosts (flattened to one label — Cloudflare Universal SSL
# only covers *.rithviknishad.dev):
#   https://care.rithviknishad.dev                   SPA (care_fe)
#   https://care-api.rithviknishad.dev               Django API
#   https://care-s3.rithviknishad.dev                MinIO (presigned URLs)
#   https://care-teleicu-gateway.rithviknishad.dev   TeleICU gateway
#   https://care-teleicu-devices.rithviknishad.dev   devices micro-frontend
#   https://mock-ptz-camera.rithviknishad.dev        mock camera web UI (admin/admin)
# Custom images are built ON the box with docker (modules/docker.nix) and
# imported straight into k3s's containerd — no registry. See docs/care.md.

care_build := ".build"

# Build + import the custom core images. care-backend:local bakes the TeleICU
# plugs in at build time (upstream pip-installs ADDITIONAL_PLUGS in the
# Dockerfile); care-fe:local compiles the API URL into the bundle (.env.local
# beats the repo's .env for Vite). Import goes through root ssh (same
# passwordless path as `just deploy`) because k3s ctr needs root.
care-images ref="develop":
    rm -rf {{care_build}}/care {{care_build}}/care_fe
    mkdir -p {{care_build}}
    git clone --depth 1 --branch {{ref}} https://github.com/ohcnetwork/care {{care_build}}/care
    docker build -t care-backend:local \
        --build-arg ADDITIONAL_PLUGS="$(cat k8s/care/additional-plugs.json)" \
        -f {{care_build}}/care/docker/prod.Dockerfile {{care_build}}/care
    git clone --depth 1 --branch {{ref}} https://github.com/ohcnetwork/care_fe {{care_build}}/care_fe
    printf 'REACT_CARE_API_URL=https://care-api.rithviknishad.dev\n' > {{care_build}}/care_fe/.env.local
    docker build -t care-fe:local {{care_build}}/care_fe
    docker save care-backend:local care-fe:local | ssh {{NIX_SSHOPTS}} {{target}} 'k3s ctr images import -'

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
# care-celery-beat, care-fe, postgres, redis, minio).
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

# Register (or update) the TeleICU devices micro-frontend as a CARE plug via
# the plug_config API, so the SPA loads its remoteEntry.js on next load. No
# UI clicks needed. Idempotent (PUT if it already exists, else POST). Needs an
# admin (is_staff) login — defaults to the load_fixtures admin/admin, so pass
# real creds on a hardened instance: `just care-register-mfe myadmin 's3cr3t'`.
care-register-mfe user="admin" pass="admin":
    #!/usr/bin/env sh
    set -eu
    api=https://care-api.rithviknishad.dev
    mfe=https://care-teleicu-devices.rithviknishad.dev
    token=$(curl -fsS -X POST "$api/api/v1/auth/login/" -H 'Content-Type: application/json' \
        -d '{"username":"{{user}}","password":"{{pass}}"}' \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access'])")
    body='{"slug":"teleicu-devices","meta":{"url":"'"$mfe"'/assets/remoteEntry.js","name":"CARE TeleICU Devices","plug":"teleicu-devices"}}'
    if curl -fsS "$api/api/v1/plug_config/" | grep -q '"teleicu-devices"'; then
        curl -fsS -X PUT "$api/api/v1/plug_config/teleicu-devices/" -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' -d "$body" >/dev/null
        echo "updated plug_config: teleicu-devices"
    else
        curl -fsS -X POST "$api/api/v1/plug_config/" -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' -d "$body" >/dev/null
        echo "created plug_config: teleicu-devices"
    fi

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
    for h in care care-api care-s3 care-teleicu-gateway care-teleicu-devices mock-ptz-camera; do \
        cloudflared tunnel route dns avocado "$h.rithviknishad.dev"; done

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
