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

## Step 7 — Post-deploy manual wiring (TeleICU, one-time, in the CARE UI)

Guide the user through it:
1. Admin → Apps → *CARE TeleICU Devices* → set the remote URL to the devices
   MFE host.
2. Create a facility, then a **Gateway device** pointing at the gateway host.
3. Copy the gateway device's ID into the gateway's `GATEWAY_DEVICE_ID` env and
   restart the middleware (this also enables automated vitals observations).
4. Add a **Camera device** (for the mock camera, use its internal ONVIF
   address, port 8080, creds `admin`/`admin`) and a **Vitals observation
   device** for the mock HL7 monitor. Onboarding is always by explicit address
   (WS-Discovery multicast usually doesn't cross container networks).

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
- **Mock PTZ camera** answers 401 on `/` without creds (still proves it's
  alive) — assert reachable + non-5xx, not strictly 200.
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
