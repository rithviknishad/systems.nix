# avocado monitoring — VictoriaMetrics + Grafana + ntfy

In-cluster observability stack for the `avocado` k3s node, mirroring
[`tellmeY18/retire.nix`](https://github.com/tellmeY18/retire.nix)'s k8s
monitoring, trimmed to a single-node box.

## What's deployed

The [`victoria-metrics-k8s-stack`](https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-metrics-k8s-stack)
Helm chart (via `helmfile.yaml` + `values.yaml`) installs:

| Component | Role |
|---|---|
| **VMSingle** | time-series database (Prometheus TSDB replacement), 15d retention on `local-path` |
| **VMAgent** | scrapes all `VM*Scrape` targets across namespaces |
| **VMAlert** | evaluates `VMRule` alerting rules |
| **VMAlertmanager** | routes alerts → the ntfy bridge |
| **Grafana** | dashboards (provisioned via ConfigMap sidecar) |
| **node-exporter** | host CPU/mem/disk/net/ZFS metrics |
| **kube-state-metrics** | Kubernetes object state |
| **VM Operator + CRDs** | `VMRule`, `VMServiceScrape`, `VMNodeScrape`, … |
| **VictoriaLogs** | log database (30d retention on `local-path`) |
| **Vector** | per-node DaemonSet shipping pod logs → VictoriaLogs |
| **Gatus** | synthetic uptime probing → ntfy.sh |

The kustomize layer (`kustomization.yaml`) adds avocado-specific glue that the
chart doesn't own:

- `namespace.yaml` — `monitoring` ns with PodSecurity labels.
- `grafana-ingress.yaml` — Traefik Ingress (the reference uses a Tailscale LB).
- `ntfy-alertmanager.yaml` — Alertmanager→ntfy.sh bridge (replaces jiralert).
- `zfs-vmrules.yaml` + `zfs-grafana-dashboard.yaml` — ZFS pool health/ARC/IO.
- `smart-vmrules.yaml` — SMART disk-health alerts (textfile collector).
- `pvc-storage-vmrules.yaml` — PVC capacity alerts.
- `cadvisor-vmnodescrape.yaml` — per-container metrics from the kubelet.
- `gatus.yaml` — synthetic uptime probing → ntfy (replaces Cloudprober).
- `victorialogs.yaml` + `vector.yaml` — log store + per-node log collector.
- `victorialogs-datasource.yaml` — Grafana logs datasource (needs the
  `victoriametrics-logs-datasource` plugin, added via `grafana.plugins`).

Standard node/k8s alerts come from the chart's `defaultRules` (etcd/scheduler/
controller-manager groups are disabled — k3s doesn't expose them).

## Host-side piece (NixOS)

`modules/monitoring.nix` runs a systemd timer that writes
`node_zfs_zpool_state` into `/var/lib/node-exporter/textfile`, which
node-exporter mounts read-only. Without it the ZFS **pool-health** alerts have
no data. Deploy it with a normal `just deploy`.

## Deploy

Prereqs: `nix develop` (gives `kubectl`, `helm`, `helmfile`, `sops`) and a
kubeconfig.

```sh
just kubeconfig      # once: writes ~/.kube/avocado

# Grafana admin password lives sops-encrypted in secrets/monitoring.enc.yaml.
# `just mon-deploy` decrypts it to the gitignored values-secret.yaml on the fly.
# To change it: `just mon-secrets`, edit, then redeploy.

just mon-deploy      # namespace + helm release + CR layer
just mon-status
```

`mon-deploy` runs, in order: `kubectl apply -f namespace.yaml` →
`helmfile sync` (installs CRDs + operator + stack) → `kubectl apply -k .`
(the CRs, which need the CRDs to exist first).

## Access Grafana

Three ways in, in order of preference:

1. **Public tunnel (with SSO):** <https://grafana.rithviknishad.dev> — served
   through the cloudflared tunnel and, once configured, gated by Cloudflare
   Access (see below). TLS terminates at Cloudflare's edge.
2. **Tailnet, via Traefik** (no public exposure):
   ```sh
   curl -H "Host: grafana.rithviknishad.dev" http://avocado
   ```
   (the `grafana-ingress.yaml` Ingress matches on that Host).
3. **Port-forward** (no ingress/tunnel at all):
   ```sh
   just mon-grafana   # -> http://localhost:3000  (admin / sops password)
   ```

## Grafana SSO via Cloudflare Access

Grafana is reachable at `grafana.rithviknishad.dev` through the tunnel. To put
single-sign-on in front of it (so you authenticate at Cloudflare's edge instead
of relying only on the admin login form), wire up **Cloudflare Access** + the
commented `auth.jwt` block in `values.yaml`:

1. **Zero Trust > Access > Applications > Add > Self-hosted.** Application
   domain `grafana.rithviknishad.dev`. Add a policy that allows your email
   (e.g. Action *Allow*, Include *Emails* → your address).
2. From the app's **Overview**, copy the **Application Audience (AUD) tag**.
   From **Zero Trust > Settings** note your **team domain**
   (`<TEAM>.cloudflareaccess.com`).
3. In `k8s/monitoring/values.yaml`, uncomment the `grafana.ini` → `auth.jwt`
   block and fill:
   - `jwk_set_url: https://<TEAM>.cloudflareaccess.com/cdn-cgi/access/certs`
   - `expect_claims: '{"aud":"<ACCESS_APP_AUD>"}'`
4. `just mon-deploy` to roll it out.

Cloudflare Access validates the login at the edge and forwards a signed
`Cf-Access-Jwt-Assertion` header; Grafana verifies it against Cloudflare's JWKS
and auto-provisions the user (Viewer by default — promote yourself once, or set
`users.auto_assign_org_role: Admin`). The built-in login form stays enabled as a
break-glass fallback. Until you create the Access application, the tunnel serves
Grafana protected only by that admin login form — so keep the sops password
strong, or don't create the DNS route until Access is live.

## ntfy notifications

VMAlertmanager forwards every alert (except the always-firing `Watchdog`) to
the `ntfy-alertmanager` bridge, which pushes to an [ntfy.sh](https://ntfy.sh)
topic.

1. **Pick a private topic.** Edit `ntfy-alertmanager.yaml` → `topic:` (default
   `avocado-alerts`). Anyone who knows a public topic name can read it, so use
   something unguessable.
2. **Subscribe** in the ntfy app / `https://ntfy.sh/<your-topic>`.
3. Severity → priority/emoji mapping: `critical` → urgent 🚨, `warning` →
   high ⚠️, resolved → ✅ (updates the original notification).
4. Test the path end-to-end:

   ```sh
   just mon-ntfy-test your-topic
   just mon-ntfy-logs           # watch alerts flow through the bridge
   ```

For a **private/authenticated** topic, put the ntfy `access-token` (or
`user`/`password`) into the sops-encrypted `secrets/monitoring.enc.yaml`
alongside the Grafana password — that file is the intended home for monitoring
secrets. Wire it into a k8s Secret referenced by the `ntfy { }` block (and
Gatus's provider) instead of the plaintext ConfigMap. Today the topic is public
(no token), so there's nothing to encrypt yet.

The bridge image is pinned to `codeberg.org/xenrox/ntfy-alertmanager:1.0.0`
(multi-arch). Bump it as new releases land.

## Uptime (Gatus)

`gatus.yaml` runs [Gatus](https://github.com/TwiN/gatus), which probes internal
services (Grafana/VMSingle/VictoriaLogs health) and public endpoints
(`rithviknishad.dev`, incl. TLS-expiry check) and pushes failures/recoveries
straight to ntfy.sh via its **native ntfy provider** — a separate pipeline from
the metrics-based Alertmanager alerts, on the same topic. Reach the dashboard
publicly at <https://status.rithviknishad.dev> (live through the tunnel), on the
tailnet via `curl -H "Host: status.rithviknishad.dev" http://avocado`, or
`just mon-gatus`.

## Logs (VictoriaLogs + Vector)

`vector.yaml` runs a Vector DaemonSet that tails every pod's logs and ships them
to **VictoriaLogs** (`victorialogs.yaml`) via its Elasticsearch bulk endpoint,
labelled by namespace/pod/container. Query them in Grafana's **Explore** with
the provisioned *VictoriaLogs* datasource, or via `just mon-logs`
(→ `http://localhost:9428/select/vmui`).

## Roadmap

- [x] **Phase 1** — VictoriaMetrics + Grafana + node-exporter + KSM, host/ZFS
      dashboards, `local-path` storage.
- [x] **Phase 2** — VMAlert rules (ZFS pool health, PVC capacity, default
      node/k8s) → VMAlertmanager → ntfy.sh.
- [x] **Phase 3 — uptime** — Gatus probes internal + public endpoints and
      pushes to ntfy.sh via its native provider (`gatus.yaml`).
- [x] **Phase 4 — logs** — VictoriaLogs + Vector DaemonSet + a Grafana logs
      datasource (`victorialogs.yaml`, `vector.yaml`,
      `victorialogs-datasource.yaml`).
- [ ] **Phase 5 — hardening**
      - [x] NetworkPolicies — default-deny ingress + minimal allow-list
            (`networkpolicies.yaml`); egress left open so scraping/ntfy work.
      - [x] Grafana admin password moved into sops
            (`secrets/monitoring.enc.yaml`, decrypted at deploy by
            `just mon-deploy`); the ntfy token has the same home for when the
            topic goes private.
      - [x] Public access via the cloudflared tunnel
            (`grafana.rithviknishad.dev`, `status.rithviknishad.dev`).
      - [ ] Grafana SSO — `auth.jwt` template + tunnel are in place; activate by
            creating a Cloudflare Access app and filling the team domain + AUD
            (see "Grafana SSO via Cloudflare Access").
- [x] **SMART disk health** — `smartctl`/`smartmon` textfile metrics + alerts
      (`modules/monitoring.nix` + `smart-vmrules.yaml`).
