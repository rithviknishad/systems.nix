---
name: deploy-care
description: Deploy Open Healthcare Network's CARE stack (care backend + care_fe + object storage + optional 10bedicu TeleICU gateway/devices/mock devices) to any target environment. Use when asked to deploy, install, set up, or re-provision CARE / ohcnetwork care / the TeleICU gateway. Walks the agent through gathering EVERY configuration choice from the user first (domain, hostname style, components, storage, secrets, monitoring, backups), then building images, wiring secrets, deploying, exposing, monitoring, and seeding data (demo fixtures vs production geo organizations). Platform-agnostic; adapt the mechanics to the target's orchestrator, ingress, secret store, and monitoring.
---

# Deploy CARE (ohcnetwork)

This skill is a **platform-agnostic playbook** for provisioning the CARE HMIS
stack. It captures what CARE needs and the traps to avoid; it does **not**
assume any particular domain, cloud, orchestrator, ingress, secret store, or
monitoring system. Learn the target environment first, then map each step onto
that environment's conventions.

Two layers appear throughout:
- **CARE-level truths** (image build behavior, env vars, migration ordering,
  gotchas) — these hold anywhere. Follow them exactly.
- **Environment mechanics** (how you build, store secrets, expose hosts,
  monitor) — these are the user's/target's choice. Ask; don't assume.

> **Reference implementation.** If this repo ships a worked CARE deployment,
> read it as one concrete example before adapting — e.g. `k8s/care/`,
> `k8s/care-teleicu/`, `docs/care.md`, and any `care-*` automation. Treat its
> specific tooling (kustomize, sops, k3s image import, Gatus, cloudflared,
> `just` recipes) as *that* environment's choices, not requirements. Any repo
> `AGENTS.md` / maintenance skill still governs there (docs in sync, atomic
> changes, ask before live/destructive actions, never print secrets).

## Step 0 — Gather ALL configuration first (do not skip)

Before touching anything, ask the user about **every** item below in one
consolidated message. Suggest a sensible option for each, but do not assume —
a wrong domain or storage choice is expensive to undo. Group the questions:

**Target environment**
- Where is this being deployed? Orchestrator (k8s/k3s, Docker Compose, …),
  ingress/reverse proxy, TLS termination, secret store, and monitoring in use.
  Everything below maps onto these.
- Fresh install or upgrade of an existing deployment?

**Scope / components**
- Core CARE only (backend + care_fe + object storage), or also the TeleICU
  layer (gateway middleware + RTSPtoWeb + devices plugin + devices MFE)?
- If TeleICU: include the **mock devices** (mock PTZ camera + mock HL7 vitals)
  for testing, or real devices only?

**Naming & exposure — do NOT assume a domain**
- **Which domain/subdomain** to serve CARE under. There is no default —
  collect it from the user (examples only: `example.org`, or a subdomain like
  `care.example.org`).
- **Hostname style** — let the user choose, and explain the tradeoff:
  - *Flattened, single-label hosts* (e.g. `care.example.org`,
    `care-api.example.org`, `care-s3.example.org`,
    `care-teleicu-gateway.example.org`, `care-teleicu-devices.example.org`).
    Covered by a one-label wildcard cert (e.g. Cloudflare Universal SSL for
    `*.example.org`).
  - *Multi-level / nested subdomains* (e.g. `care.example.org`,
    `api.care.example.org`, `s3.care.example.org`,
    `gateway.teleicu.care.example.org`). Cleaner hierarchy, but a single-label
    wildcard does NOT cover a second label — nested hosts need a multi-level /
    per-host cert (ACM, Total TLS, or SANs on your own cert). Confirm the
    user's TLS can cover them before choosing nested.
- Record the resolved hosts for: SPA (care_fe), API (backend), object-storage
  public endpoint, and (if TeleICU) gateway + devices MFE. Every manifest /
  env var / ingress / DNS / monitoring reference downstream uses these. The
  example values here are illustrative only.
- How are these exposed? (public reverse proxy / tunnel, VPN-only, internal.)

**Image sources / builds**
- Git ref for `care` and `care_fe` (e.g. `develop`, or a pinned tag). TeleICU
  MFE + mock camera track their default branch unless told otherwise.
- Registry vs local build+load (see Step 2). Where do built images land?

**Object storage** (required — CARE needs S3 for file uploads)
- In-cluster/self-hosted MinIO, or external S3-compatible (AWS/GCP/R2/B2)? If
  external, collect endpoint, **external endpoint**, region, bucket names, and
  credentials.
- Bucket names (e.g. patient uploads, facility assets, and a TeleICU snapshot
  bucket if used) and any volume sizes.

**Databases & storage sizes**
- Postgres for CARE (and a separate one for the TeleICU gateway if used):
  managed service or in-cluster? Volume sizes. Redis likewise.

**Backups**
- DB backup method, schedule, retention (e.g. nightly `pg_dump`). Offsite
  copy? If the storage has no redundancy, say so explicitly — a same-disk
  backup is NOT disaster recovery.

**Backend settings**
- `CORS_ALLOWED_ORIGINS` / `CSRF_TRUSTED_ORIGINS` (the resolved SPA + API
  hosts), `CURRENT_DOMAIN`, `BACKEND_DOMAIN`.
- `ADDITIONAL_PLUGS` — which plugins to bake in (for TeleICU: the three
  `care_teleicu_devices` plugs — `gateway_device`, `camera_device`,
  `vitals_observation_device`).
- Optional: SMTP (`EMAIL_HOST`/`EMAIL_PORT`/`EMAIL_HOST_USER`/
  `EMAIL_HOST_PASSWORD`/`EMAIL_FROM`), `SENTRY_DSN`, rate limits, TLS-redirect
  behavior (disable Django's forced SSL redirect if TLS terminates at the edge
  and the app is reached over plain http internally).

**Secrets** (generate strong random values; never print them)
- Postgres password(s), `DJANGO_SECRET_KEY`, object-storage credentials, and a
  **stable `JWKS_BASE64` per Django app**. CARE and the TeleICU gateway each
  need their OWN key set — an unset one regenerates on every restart and
  invalidates all sessions/trust. Store via the target's secret mechanism.

**Data seeding** — ask explicitly (see Step 6):
- **Demo/testing** → `load_fixtures` (orgs, facility, demo users, sample
  patients; also creates a weak `admin`/`admin`).
- **Production** → geo organizations ONLY via `load_govt_organization_csv`
  (state/district/local-body/ward hierarchy) + a real superuser. No demo
  patients or throwaway accounts. Get the geo CSV URL from the user.

Only proceed once the user has answered or accepted your suggestions.

## Step 1 — Prerequisites

Confirm you can reach the target's control plane (kubeconfig / compose host /
API), that a build environment is available if building locally, and that
whatever issues DNS + certs for the chosen hosts is in place. Adapt to the
environment — don't hardcode a specific box's tooling.

## Step 2 — Build & obtain images

Some images can't be used from upstream registries as-is and must be built:
- **`care` backend** — plugins install at **build time** (`ADDITIONAL_PLUGS`
  is consumed by `docker/prod.Dockerfile`'s builder stage via
  `install_plugins.py`), so enabling any plug means building a custom image.
- **`care_fe`** — the API URL is compiled into the bundle at build time
  (`REACT_CARE_API_URL`, Vite), so it must be built against the chosen API
  host.
- **TeleICU devices MFE** and **mock PTZ camera** — upstream publishes no
  image; build from their Dockerfiles.
- The TeleICU **gateway** and **mock vitals** images are published upstream.

Build with the target's pipeline (CI→registry, or local `docker build` + load
into the orchestrator, e.g. `k3s ctr images import` / `kind load` / a
registry push). If using local-only images, set the workload's image pull
policy so a missing load fails loudly rather than pulling something else.

Verify the plugin baked in before deploying, e.g.:
`docker run --rm --entrypoint python <care-backend-image> -c "import gateway_device, camera_device, vitals_observation_device"`

Keep the `ADDITIONAL_PLUGS` **build arg** and the **runtime env** semantically
identical — the build installs the pip packages; the runtime value adds them
to `INSTALLED_APPS`.

## Step 3 — Secrets

Materialize the secrets from Step 0 into the target's secret store (k8s
Secret, sops-encrypted manifest, compose `.env`, a vault, …). Generate
`JWKS_BASE64` with any image that has `authlib` (e.g. the built backend image).
Never print secret values, never commit plaintext, and clean up any scratch
files used to generate them. Sanity-check the secret applies/loads before
deploying.

## Step 4 — Deploy + expose

Bring up, in order: object storage (+ create buckets), Postgres, Redis, the
CARE backend (API + celery worker + celery **beat**), care_fe, and (if chosen)
the TeleICU stack. Then wire DNS for the resolved hosts and expose them through
the target's ingress/tunnel.

- **Migration ordering:** upstream's compose runs migrations from the **celery
  beat** entrypoint (`celery_beat.sh` → migrate + `sync_permissions_roles` +
  `sync_valueset`, then beat). Preserve this: let beat run migrations and have
  the API tolerate 500s until they finish (first migrate + valueset sync takes
  several minutes). Use readiness/health gating so the API stays out of
  rotation until ready.
- Watch the workloads settle and confirm each becomes healthy.

## Step 5 — Monitoring

Add uptime/health monitoring for the resolved public endpoints using
**whatever monitoring the target environment uses** (Gatus, Blackbox exporter,
UptimeRobot, a cloud check, …). Good signals:
- care_fe host → `/` (200)
- API host → `/ping/` (200, body `{"status": "OK"}`)
- object-storage public host → `/minio/health/live` (200) if MinIO
- TeleICU gateway host → `/` (200; note its nginx 404s on `/test`)
- devices MFE host → `/health` (200)
- physical ONVIF cameras → raw **TCP connect to the RTSP port (554)** (the
  video pipeline is on-demand + token-gated, so a camera's power/network drop
  is the only cleanly probeable failure); one probe per onboarded camera.
  Consider a dedicated cameras subgroup separate from the main service group
  (e.g. teleicu/cameras), since cameras are numerous, site-specific, and
  physically fragile — you don't want their flakiness diluting the core
  stack's status.
- add certificate-expiry checks for public HTTPS endpoints
Probe in-cluster-only components via their internal service address. If the
repo has an existing monitoring config, extend it (and follow its refresh
ritual, e.g. bumping a config checksum) rather than inventing a parallel one.

## Step 6 — Seed data (ask demo vs production — Step 0)

Both are `manage.py` commands run in the CARE backend container.

**Demo / testing** — `load_fixtures` is a dev command with two upstream guards
to work around:
1. `faker` isn't in the prod image → install it into the running container
   first (ephemeral; image stays clean).
2. It refuses to run unless `settings.DEBUG` → scope `DJANGO_DEBUG=true` to
   just that one command invocation.

```sh
<exec-into-backend> -- pip install faker
<exec-into-backend> -- env DJANGO_DEBUG=true python manage.py load_fixtures
```

It prints demo users (`care-doctor` … `Ohcn@123`) and creates a weak
**`admin`/`admin`** — on any reachable instance, immediately change it
(`python manage.py changepassword admin`) and warn the user.

**Production** — load geo organizations only, then a real superuser:

```sh
<exec-into-backend> -- python manage.py load_govt_organization_csv <geo_csv_url>   # idempotent, no DEBUG needed
<exec-into-backend> -- python manage.py createsuperuser                            # interactive — the user runs this
```

`load_govt_organization_csv` expects CSV columns: State, District, Local Body,
Local Body Type, Grama Panchayat, Ward Number, Ward Name. Do NOT run
`load_fixtures` on a production instance (it seeds demo patients and weak
accounts).

## Step 7 — Post-deploy wiring (TeleICU, one-time)

1. **Register the devices MFE** — this is a plain API call, not a UI chore, so
   do it yourself rather than walking the user through clicks. CARE exposes a
   `plug_config` endpoint the SPA reads on load to pull micro-frontend
   remotes:
   - `GET /api/v1/plug_config/` — public, returns `{"configs": [...]}`.
   - `POST /api/v1/plug_config/` (create) / `PUT /api/v1/plug_config/<slug>/`
     (update) — require an **admin (`is_staff`) JWT** (obtain via
     `POST /api/v1/auth/login/`, use the `access` token as
     `Authorization: Bearer`).
   The record is `{ "slug": "...", "meta": { ... } }` (model: `slug` unique +
   `meta` JSON). For the TeleICU devices MFE:
   ```json
   {
     "slug": "teleicu-devices",
     "meta": {
       "url": "<devices-MFE-host>/assets/remoteEntry.js",
       "name": "CARE TeleICU Devices",
       "plug": "teleicu-devices"
     }
   }
   ```
   Confirm the exact `remoteEntry.js` path against the deployed MFE first
   (module-federation Vite builds usually emit `/assets/remoteEntry.js`; a
   bare `/remoteEntry.js` often 404s). Make the call idempotent (PUT if the
   slug already exists, else POST) and verify via the public `GET`. The MFE's
   nginx already serves `Access-Control-Allow-Origin: *`, so the cross-origin
   remote load works. If the environment provides admin creds only via the
   demo `admin`/`admin` from `load_fixtures`, use them but flag that they must
   be rotated. (The older Admin → Apps UI flow does the same thing; prefer the
   API so the step is scriptable/repeatable.)
2. **Create a facility, then a Gateway device** — also API-drivable, so do it
   yourself. The gateway device is `POST
   /api/v1/facility/<facility_id>/device/` (admin token) with
   `care_type: "gateway"`, `status`/`availability_status` active/available,
   and `endpoint_address` (+ `insecure`) set to the gateway host — CARE nests
   these under `care_metadata` in the response. Grab the response's **`id`**
   (a UUID): that is the gateway device ID. (A facility likewise has a create
   API; `load_fixtures` also seeds one you can reuse.)
3. Put that `id` into the gateway's `GATEWAY_DEVICE_ID` env and restart the
   middleware (this also enables automated vitals observations). The
   middleware signs JWTs with its JWKS and sends the ID as `X-Gateway-Id` on
   its CARE calls; CARE matches it to the registered device to authorize.
4. **Add a Camera device (ONVIF).** A camera device is only useful once it has
   a **`stream_id`** — a stream registered in the RTSP-to-web server
   (RTSPtoWeb). The gateway does NOT produce this: its camera API only does
   PTZ/status, and nothing syncs CARE cameras back into RTSPtoWeb. So onboard
   in two steps:
   1. **Register the RTSP feed → stream_id.** ONVIF is the only reliable way to
      get the camera's RTSP URL (the path is vendor-specific — never guess it).
      Call ONVIF `GetStreamUri` (from a component that has an ONVIF client —
      the gateway image ships `onvif-zeep`), bake URL-encoded credentials into
      the returned RTSP URL, and register it with RTSPtoWeb
      (`POST /stream/<id>/add`, or `/edit` if the id already exists). Pick the
      `stream_id` yourself (a UUID). On this repo that whole flow is
      `just care-register-camera <ip> <user> <pass> [profile] [onvif_port] [stream_id]`
      (`k8s/care-teleicu/scripts/register-camera-stream.py`), which prints the
      id.
   2. **Create the device** — `POST /api/v1/facility/<facility_id>/device/`
      (admin token) with `care_type: "camera"`, `type: "ONVIF"`, the `gateway`
      device id, the camera's `endpoint_address`/`username`/`password`, and the
      `stream_id` from step 1. Response `id` is the camera device id.
   3. **Persist the stream declaratively** (see next note) so it survives a
      stream-server/node restart — the runtime registration in step 1 does not.

   Also add a **Vitals observation device** for the mock HL7 monitor.
   Onboarding is always by explicit address (WS-Discovery multicast usually
   doesn't cross container networks). For the mock PTZ camera use its internal
   ONVIF address on port 8080, creds `admin`/`admin`.

   **When a user asks to set up an ONVIF camera, first ask for its IP address
   and credentials if they weren't provided** — you need them for both the ONVIF
   GetStreamUri and the device payload.

   **Make camera streams declarative (survive restarts).** `care-register-camera`
   writes to RTSPtoWeb's API at runtime → the stream lives only in the pod's
   emptyDir and is lost on any restart. The durable fix is to bake the full
   RTSPtoWeb `config.json` (server block + per-camera `streams`) into a seed the
   stream-server copies into its emptyDir on **every** start. On this repo the
   seed is the sops-encrypted `RTSPTOWEB_CONFIG_JSON` key of `teleicu-secret`
   (streams can't be a plaintext ConfigMap — each channel URL embeds the
   camera's `username:password`). Workflow: `just care-resolve-camera <ip>
   <user> <pass> <stream_id> [profile] [onvif_port]`
   (`k8s/care-teleicu/scripts/resolve-camera-stream.py`) prints the camera's
   `streams` fragment; merge it under `"streams"` via `just care-teleicu-secrets`,
   then `just care-teleicu-deploy` + `kubectl -n care-teleicu rollout restart
   deploy/stream-server`. The `stream_id` key MUST equal the CARE device's
   `stream_id`. On another platform, mirror this: keep the config in your
   secret store, mount it, seed a writable copy at pod start.

## Gotchas (CARE-level — hold on any platform)

- **Docker service-link env collisions.** On k8s, a `postgres` Service injects
  `POSTGRES_PORT=tcp://…`, which upstream's `wait_for_db.sh` misreads as a port
  number and dies. Disable service-link injection (k8s
  `enableServiceLinks: false`) and/or pass explicit `POSTGRES_HOST` /
  `POSTGRES_PORT`. The same applies to the TeleICU Django pods.
- **care_fe API URL is build-time baked** (`REACT_CARE_API_URL` via Vite; a
  `.env.local` beats the repo's `.env`). Changing the API host = rebuild.
- **TeleICU gateway nginx hardcodes upstream hostnames** — the middleware and
  stream-server services MUST be named `teleicu-middleware` and
  `stream-server`. Its `/test` path may 404 in the published image; probe `/`.
- **Devices MFE `remoteEntry.js` path** — confirm it against the deployed MFE
  before registering the plug; module-federation Vite builds emit
  `/assets/remoteEntry.js`, and a bare `/remoteEntry.js` typically 404s.
- **Mock PTZ camera** answers 401 on `/` without creds (still proves it's
  alive) — assert reachable + non-5xx, not strictly 200.
- **Camera streams must be declarative, or they vanish on restart.** RTSPtoWeb
  keeps streams in memory/emptyDir; registering via its API at runtime is
  ephemeral, so a stream-server/node restart silently breaks every camera feed.
  Seed the full `config.json` (incl. `streams`) from a mounted secret on every
  pod start so cameras auto-restore. Runtime registration is fine for a quick
  test, but persist anything real (on this repo: `RTSPTOWEB_CONFIG_JSON` in the
  sops `teleicu-secret`; `just care-resolve-camera` prints the fragment).
- **Mock ventilator** may crash-loop: current gateway images' pydantic
  Observation enum rejects ventilator metrics (PEEP…). Park it disabled; the
  HL7 monitor mock covers the vitals flow.
- **Object storage split endpoints:** CARE hands browsers **presigned URLs**
  built from the *external* endpoint (`BUCKET_EXTERNAL_ENDPOINT`), distinct
  from the internal `BUCKET_ENDPOINT` the backend uses. The external endpoint
  must be publicly reachable. Mind any edge request-body size caps (e.g. some
  free CDN tiers cap uploads ~100MB).
- **Migrations run from celery beat**, not the API — preserve that ordering.

## Validation / definition of done

- Manifests/compose render or validate cleanly; any repo-specific checks pass.
- Every resolved public endpoint returns its expected code (SPA 200, API
  `/ping/` OK, gateway 200, MFE `/health`, object storage health 200).
- Monitoring shows the CARE endpoints healthy.
- A backup run produces a restorable dump.
- If deployed from a repo: docs/config updated in sync; working tree clean of
  secrets and build scratch.
