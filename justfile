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
