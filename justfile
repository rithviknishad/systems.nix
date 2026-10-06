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

# --- suchi (self-hosted document archive) ------------------------------------
# One `suchi serve` process: SQLite + content-addressed blobs + the credential
# key, all on one 50Gi PVC (local-path-retain, so it survives a namespace
# delete). Upstream -full image (OCRmyPDF) pinned by digest; no secret needed.
# Gated by suchi's own accounts rather than Cloudflare Access, because the
# Companion mobile app and API-token clients must reach it directly.
#   https://suchi.rithviknishad.dev   web app + API, public
#   http://suchi.suchi.svc:8000       in-cluster
# See docs/suchi.md.

# Deploy/upgrade suchi (kustomize). Upgrades = bump the digest in
# k8s/suchi/suchi.yaml after the backup checklist in docs/suchi.md.
suchi-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/suchi

# Show the state of the suchi namespace.
suchi-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n suchi get pods,svc,ingress,pvc

# Tail the suchi server logs.
suchi-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n suchi logs -f deploy/suchi

# Only logged while no admin exists; it's a one-time credential, so treat the
# output as a secret and use it immediately at /bootstrap.
# Print the first-boot setup token for creating the first admin.
suchi-setup-token:
    KUBECONFIG={{kubeconfig_path}} kubectl -n suchi logs deploy/suchi | grep token_minted

# Reports schema, filesystem, OCR binaries/languages, job health and the
# active egress list — without printing secrets.
# Run `suchi doctor` inside the running pod.
suchi-doctor:
    KUBECONFIG={{kubeconfig_path}} kubectl -n suchi exec deploy/suchi -- suchi doctor

# Run any suchi CLI subcommand inside the running pod (e.g. `just suchi-cli gc`).
suchi-cli *args:
    KUBECONFIG={{kubeconfig_path}} kubectl -n suchi exec -it deploy/suchi -- suchi {{args}}

# Break-glass access when the Cloudflare edge is down: http://localhost:8000.
# Port-forward suchi to http://localhost:8000.
suchi-ui:
    KUBECONFIG={{kubeconfig_path}} kubectl -n suchi port-forward svc/suchi 8000:8000

# Needs the cloudflared login cert (cloudflared tunnel login) on this machine.
# One-time: point the public suchi hostname at the tunnel.
suchi-dns:
    cloudflared tunnel route dns avocado suchi.rithviknishad.dev

# --- Mailpit (Mailtrap-style SMTP sink + web inbox) ---------------------------
# Catches all mail sent to it; nothing is delivered for real. Dev/staging mail
# server for the Care SaaS (csaas-*) stack. SMTP needs auth; the inbox has its
# own separate basic-auth credential. Both live in secrets/mailpit.enc.yaml.
#   mailpit.mailpit.svc.cluster.local:1025   SMTP, in-cluster
#   avocado:1025                             SMTP, tailnet (+ LAN)
#   https://mailpit.rithviknishad.dev        web inbox, public
#   http://avocado:8025                      web inbox, tailnet (+ LAN)
# See docs/mailpit.md.

# Applies the kustomize manifests, then pipes the sops-encrypted auth Secret
# straight into kubectl (plaintext never touches disk), then restarts the pod
# because Mailpit only reads its password files at startup.
# Deploy/upgrade Mailpit (manifests + sops auth secret + restart).
mailpit-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/mailpit
    sops --decrypt secrets/mailpit.enc.yaml \
        | KUBECONFIG={{kubeconfig_path}} kubectl apply -f -
    KUBECONFIG={{kubeconfig_path}} kubectl -n mailpit rollout restart deploy/mailpit

# Show the state of the mailpit namespace.
mailpit-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n mailpit get pods,svc,ingress,pvc

# Tail the Mailpit logs.
mailpit-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n mailpit logs -f deploy/mailpit

# Log in with the `ui-auth` credential from secrets/mailpit.enc.yaml.
# Port-forward the Mailpit inbox to http://localhost:8025.
mailpit-ui:
    KUBECONFIG={{kubeconfig_path}} kubectl -n mailpit port-forward svc/mailpit 8025:8025

# Redeploy after, and update any app holding the SMTP password (incl.
# ~/csaas-bootstrap/mailtrap-smtp.env).
# Edit the sops-encrypted Mailpit auth secret (SMTP + web UI password files).
mailpit-secrets:
    sops secrets/mailpit.enc.yaml

# Re-encrypt the Mailpit secret after changing recipients in .sops.yaml.
mailpit-secrets-rekey:
    sops updatekeys secrets/mailpit.enc.yaml

# Needs the cloudflared login cert (cloudflared tunnel login) on this machine.
# One-time: point the public Mailpit hostname at the tunnel.
mailpit-dns:
    cloudflared tunnel route dns avocado mailpit.rithviknishad.dev

# --- App gallery (Homepage launcher) ------------------------------------------
# Public launcher listing every exposed app, with cluster/host stats:
#   https://apps.rithviknishad.dev   public (tunnel, no auth by design)
#   http://apps.avocado.local        LAN/tailnet via Traefik
# Tiles come from `gethomepage.dev/*` annotations on each app's own Ingress, so
# they go live with that app's deploy (e.g. `just mailpit-deploy`), not this one.
# See docs/apps.md.

# Homepage reads its config at startup: bump `checksum/config` in
# k8s/homepage/homepage.yaml after editing the ConfigMap, or the pod won't roll.
# Deploy/upgrade the gallery (namespace, RBAC, config, Deployment, Ingress).
apps-deploy:
    KUBECONFIG={{kubeconfig_path}} kubectl apply -k k8s/homepage

# Show the state of the homepage namespace.
apps-status:
    KUBECONFIG={{kubeconfig_path}} kubectl -n homepage get pods,svc,ingress

# Tail the Homepage logs (discovery/RBAC errors and widget failures land here).
apps-logs:
    KUBECONFIG={{kubeconfig_path}} kubectl -n homepage logs -f deploy/homepage

# Needs the cloudflared login cert (cloudflared tunnel login) on this machine.
# One-time: point the public gallery hostname at the tunnel.
apps-dns:
    cloudflared tunnel route dns avocado apps.rithviknishad.dev

# --- lumine: CARE in a box (https://care-box.rithviknishad.dev) --------------
# Raspberry Pi 5 on Raspberry Pi OS (no Nix, no k8s): CARE as plain systemd
# units, configured from lumine/. This machine (avocado or the Mac) is its
# control plane: the recipes run HERE and drive lumine over SSH + sudo. The
# box has no repo checkout and no sops: `box-sync` ships lumine/ to a
# root-owned copy on the box, and secrets are decrypted here and streamed in
# over SSH. See docs/care-box.md.

box_ssh    := "rithviknishad@lumine"
box_ops    := "/usr/local/lib/care-box"
box_origin := "https://care-box.rithviknishad.dev"

# Root-owned and read-only to everyone else: root runs these, so the care
# user (which owns /opt/care) must not be able to rewrite them. PLAN.md stays
# behind; avocado's plug list and this checkout's revision ride along for
# deploy-backend.sh. Every recipe that runs a script on the box syncs first.
# Ship lumine/ (scripts + config) to the box's /usr/local/lib/care-box.
box-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    chmod 755 "$stage"
    rsync -a --exclude PLAN.md lumine/ "$stage/"
    cp k8s/care/additional-plugs.json "$stage/care/"
    rev=$(git rev-parse --short HEAD)
    [ -z "$(git status --porcelain -- lumine k8s/care/additional-plugs.json)" ] || rev=$rev-dirty
    echo "$rev" >"$stage/SYSTEMS_NIX_REVISION"
    rsync -rlpt --delete --rsync-path='sudo rsync' --chown=root:root --chmod=go-w \
        "$stage/" "{{box_ssh}}:{{box_ops}}/"

# Packages, cloudflared apt repo, pinned VersityGW, the care user/dirs,
# Postgres tuning + role, units, nginx site, tunnel config. Idempotent: run it
# after editing anything under lumine/.
# Converge lumine's base system (lumine/provision.sh).
box-provision: box-sync
    ssh {{box_ssh}} sudo {{box_ops}}/provision.sh

# Kept out of box-provision so upgrades are always deliberate. Kernel and
# firmware updates take effect on the next reboot (ask before rebooting).
# apt full-upgrade lumine.
box-upgrade:
    ssh -t {{box_ssh}} 'sudo apt-get update -q && sudo DEBIAN_FRONTEND=noninteractive apt-get -y -q full-upgrade'

# Decrypted HERE with this machine's age key; the plaintext goes to the box
# only over SSH stdin (never argv, never a temp file) and lands in root-only
# files there, one per consumer: /etc/care/care.env (care-*),
# /etc/care/versitygw.env, the tunnel creds. Values are never printed; the
# env files are checked through systemd's own parser. Restarts whatever
# consumes a changed file.
# Render lumine's secrets onto the box (lumine/render-secrets.sh).
box-secrets-render: box-sync
    #!/usr/bin/env bash
    set -euo pipefail
    app=$(sops -d secrets/care-box.enc.env)
    tunnel=$(sops -d --input-type binary --output-type binary secrets/lumine-cloudflared.json | base64 | tr -d '\n')
    printf '%s\n_TUNNEL_JSON_B64=%s\n' "$app" "$tunnel" | ssh {{box_ssh}} sudo {{box_ops}}/render-secrets.sh

# Then: just box-secrets-render.
# Edit lumine's app secrets (secrets/care-box.enc.env).
box-secrets:
    sops secrets/care-box.enc.env

# Defaults to the tracked branch (lumine/care/deploy-backend.sh); a no-op when
# the running release already is its head with the same plugs + settings.
# Restarts care.target, which blocks until beat's migrations are done, then
# waits for gunicorn to answer:
#   just box-deploy                                   # tracked branch head
#   just box-deploy develop ohcnetwork/care           # another ref/repo
# Build + roll out the CARE backend on lumine (lumine/care/deploy-backend.sh).
[positional-arguments]
box-deploy *args: box-sync && _box-wait-api
    #!/usr/bin/env bash
    set -euo pipefail
    q=; [ $# -eq 0 ] || q=$(printf '%q ' "$@")
    ssh {{box_ssh}} sudo {{box_ops}}/care/deploy-backend.sh "$q"

# The backend only (beat + API + worker); postgres, redis, VersityGW, nginx
# and the tunnel keep running. Not persistent: care.target is enabled, so a
# reboot starts it again. The services are named explicitly so systemctl
# waits for them to be down (a stop of the target alone returns first).
# Stop / start / restart CARE on lumine (care.target).
box-stop:
    ssh {{box_ssh}} sudo systemctl stop care.target care-api.service care-worker.service care-beat.service

# Beat re-runs migrations before the API + worker start; both recipes wait
# for that and then for gunicorn to answer.
box-start: && _box-wait-api
    ssh {{box_ssh}} sudo systemctl start care.target

box-restart: && _box-wait-api
    ssh {{box_ssh}} sudo systemctl restart care.target

# gunicorn --preload imports Django before it listens: ~10 s on the Pi after
# its unit is already "active".
[private]
_box-wait-api:
    #!/usr/bin/env bash
    ssh {{box_ssh}} bash -s <<'EOF'
    for _ in $(seq 60); do
      if curl -fs -m 2 -o /dev/null -H 'Host: care-box.rithviknishad.dev' http://127.0.0.1:9000/api/v1/plug_config/; then
        echo "care-api ready"
        exit 0
      fi
      sleep 2
    done
    echo "care-api not answering after 120 s: just box-logs care-api" >&2
    exit 1
    EOF

# Takes the public URL down (Cloudflare then serves its own 530 error page)
# while the backend keeps running for maintenance over SSH. Not persistent
# across reboots either.
# Cut / restore care-box's public access (the lumine tunnel).
box-offline:
    ssh {{box_ssh}} sudo systemctl stop cloudflared-lumine.service

box-online:
    ssh {{box_ssh}} sudo systemctl start cloudflared-lumine.service

# Fixtures load only once (demo users + Ohcn@123 passwords, public!); the
# password step runs every time. The password is decrypted HERE and reaches
# the box on SSH stdin only. See lumine/care/seed-demo.sh.
# Load CARE's demo fixtures, then set admin's password from BOX_ADMIN_PASSWORD.
box-seed-demo: box-sync
    #!/usr/bin/env bash
    set -euo pipefail
    pw=$(sops -d secrets/care-box.enc.env | sed -n 's/^BOX_ADMIN_PASSWORD=//p')
    printf '%s\n' "$pw" | ssh {{box_ssh}} sudo {{box_ops}}/care/seed-demo.sh

# Via the ORM on the box (no admin credentials); clears the cached plug list.
# Register the ABDM MFE (plug_config `abdm`) for the care-box origin.
box-register-abdm: box-sync
    ssh {{box_ssh}} sudo {{box_ops}}/care/manage.sh shell -v 0 < lumine/care/register_abdm.py

# Mirrors avocado's versitygw-buckets Job (minus TeleICU's bucket).
# Create CARE's buckets + the care-facility policy on VersityGW. Idempotent.
box-buckets: box-sync
    ssh {{box_ssh}} sudo {{box_ops}}/care/buckets.sh

# Show lumine's units, running revisions, memory, disk and Pi health.
box-status:
    #!/usr/bin/env bash
    ssh {{box_ssh}} bash -s <<'EOF'
    systemctl list-units --no-pager --all 'care*' postgresql@17-main.service redis-server.service nginx.service versitygw.service cloudflared-lumine.service
    for d in backend fe abdm-fe; do
      echo "--- $d: $(readlink /opt/care/$d/current)"
      grep -E '^(repo|ref|sha|systems.nix)=' /opt/care/$d/current/REVISION 2>/dev/null || echo "not deployed"
    done
    echo "--- ops scripts: systems.nix $(cat /usr/local/lib/care-box/SYSTEMS_NIX_REVISION 2>/dev/null || echo 'not synced')"
    echo "--- system"
    uptime
    free -h
    df -h / /boot/firmware
    echo "$(vcgencmd measure_temp) $(vcgencmd get_throttled) (0x0 = never throttled/under-volted since boot)"
    EOF

# Every unit active and nothing failed, the local endpoints (postgres, redis,
# VersityGW, gunicorn, nginx) on the box, then the public URL end to end
# through Cloudflare. Exits non-zero if anything is down, so it's scriptable.
# Health-check care-box: units + local endpoints on lumine, then the public URL.
box-health:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    echo "--- on lumine"
    ssh {{box_ssh}} bash -s <<'EOF' || rc=1
    rc=0
    check() { if "${@:2}" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  FAIL  $1"; rc=1; fi; }
    for u in postgresql@17-main redis-server nginx versitygw cloudflared-lumine care-beat care-api care-worker; do
      check "unit $u" systemctl is-active --quiet "$u"
    done
    check "no failed units" test -z "$(systemctl --failed --no-legend --plain)"
    check "postgres accepts connections" pg_isready -q
    check "redis PING" redis-cli ping
    host='Host: care-box.rithviknishad.dev'
    check "versitygw /health" curl -fsS -m 5 http://127.0.0.1:7070/health
    check "gunicorn /api/v1/plug_config/" curl -fsS -m 10 -H "$host" http://127.0.0.1:9000/api/v1/plug_config/
    check "nginx / (SPA)" curl -fsS -m 5 -H "$host" http://127.0.0.1/
    exit $rc
    EOF
    echo "--- public ({{box_origin}})"
    for path in / /api/v1/plug_config/ /api/abdm/health /mfe-plugs/abdm/assets/remoteEntry.js; do
      if curl -fsS -m 15 -o /dev/null "{{box_origin}}$path"; then echo "  ok    $path"; else echo "  FAIL  $path"; rc=1; fi
    done
    exit $rc

# Follow the journal of every care-* unit, or one: just box-logs care-beat.
box-logs unit="care-*":
    ssh -t {{box_ssh}} "sudo journalctl -f -u '{{unit}}'"

# Interactive commands get a pty: just box-manage createsuperuser. Arguments
# are shell-quoted for the remote side, so they arrive exactly as given.
# Run manage.py on lumine as care with the units' environment (lumine/care/manage.sh).
[positional-arguments]
box-manage *args: box-sync
    #!/usr/bin/env bash
    set -euo pipefail
    t=-T; if [ -t 0 ] && [ -t 1 ]; then t=-t; fi
    q=; [ $# -eq 0 ] || q=$(printf '%q ' "$@")
    ssh "$t" {{box_ssh}} sudo {{box_ops}}/care/manage.sh "$q"

# SSH into lumine.
box-ssh:
    ssh {{box_ssh}}

# Run ON AVOCADO: the Vite build needs ~4 GB of RAM and lumine has 2 GB, while
# the output is architecture-independent static files. Builds care_fe at the
# head of `ref` with the care-box origin baked in (same .env.local as
# care-fe-image), and the ABDM MFE from k8s/care/abdm-fe at the sha pinned in
# additional-plugs.json (identical to avocado's: the MFE bakes in no origin).
# Copies the files out of the images and rsyncs them to lumine as
# /opt/care/{fe,abdm-fe}/<id>/{html,REVISION}, then flips each `current`
# symlink; nginx serves the new files on the next request. Keeps the two
# previous builds of each (rollback: `sudo ln -sfn <id> /opt/care/fe/current`
# on lumine). Skips a half whose <id> (sha + build config) is already live.
# Build care_fe + the ABDM MFE for care-box and ship them to lumine.
box-fe ref="bodhi/questionnaire-actions" repo="ohcnetwork/care_fe":
    #!/usr/bin/env bash
    set -euo pipefail
    envlocal='REACT_CARE_API_URL={{box_origin}}\nREACT_MFE_REGISTERED_COMPONENTS=AddFacilitySheet\n'
    sha=$(git ls-remote https://github.com/{{repo}} refs/heads/{{ref}} | cut -f1)
    [ -n "$sha" ] || { echo "no branch {{ref}} in {{repo}}" >&2; exit 1; }
    abdm=$(python3 -c 'import json; print(next(p for p in json.load(open("k8s/care/additional-plugs.json")) if p["name"] == "abdm")["package_name"].split("@")[1].split("#")[0])')
    fe_id=${sha:0:12}-$(printf "$envlocal" | sha256sum | cut -c1-8)
    abdm_id=${abdm:0:12}-$(cat k8s/care/abdm-fe/* | sha256sum | cut -c1-8)
    live() { [ "$(ssh {{box_ssh}} readlink "/opt/care/$1/current" || true)" = "$2" ]; }
    out=$(mktemp -d)
    trap 'rm -rf "$out"' EXIT
    # Static files out of an image, without running it.
    extract() { local cid; cid=$(docker create "$1"); docker cp "$cid:$2" "$3"; docker rm "$cid" >/dev/null; }
    # Upload as root-owned read-only files, then flip `current` + prune.
    ship() {
        ssh {{box_ssh}} sudo install -d -m 755 "/opt/care/$1"
        rsync -a --delete --rsync-path='sudo rsync' --chown=root:root --chmod=D755,F644 \
            "$3/" "{{box_ssh}}:/opt/care/$1/$2/"
        ssh {{box_ssh}} sudo sh -seu -- "$1" "$2" <<'EOF'
    d=/opt/care/$1; id=$2
    ln -sfn "$id" "$d/current.new"
    mv -T "$d/current.new" "$d/current"
    find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' | sort -rn | cut -d' ' -f2 |
        grep -vx "$id" | tail -n +3 | while read -r old; do rm -rf "${d:?}/$old"; echo "pruned $1/$old"; done
    EOF
        echo "care-box $1 -> $2"
    }
    if live fe "$fe_id"; then
        echo "fe up to date: {{repo}}@{{ref}} = $fe_id"
    else
        src={{care_build}}/care_fe-box
        rm -rf "$src"
        mkdir -p {{care_build}}
        git clone -q --depth 1 --branch {{ref}} https://github.com/{{repo}} "$src"
        [ "$(git -C "$src" rev-parse HEAD)" = "$sha" ] || { echo "{{ref}} moved during the build; re-run" >&2; exit 1; }
        printf "$envlocal" >"$src/.env.local"
        docker build -t care-fe:box "$src"
        mkdir -p "$out/fe/html"
        extract care-fe:box /usr/share/nginx/html/. "$out/fe/html/"
        printf 'repo={{repo}}\nref={{ref}}\nsha=%s\nbuilt=%s\n' "$sha" "$(date -Iseconds)" >"$out/fe/REVISION"
        ship fe "$fe_id" "$out/fe"
    fi
    if live abdm-fe "$abdm_id"; then
        echo "abdm-fe up to date: care-abdm@$abdm = $abdm_id"
    else
        docker build -t care-abdm-fe:box --build-arg CARE_ABDM_REF="$abdm" k8s/care/abdm-fe
        mkdir -p "$out/abdm-fe/html"
        extract care-abdm-fe:box /usr/share/nginx/html/mfe-plugs "$out/abdm-fe/html/"
        printf 'repo=ohcnetwork/care-abdm\nsha=%s\nbuilt=%s\n' "$abdm" "$(date -Iseconds)" >"$out/abdm-fe/REVISION"
        ship abdm-fe "$abdm_id" "$out/abdm-fe"
    fi
