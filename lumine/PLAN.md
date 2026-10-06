# lumine — CARE in a box (`care-box.rithviknishad.dev`)

Working plan for running CARE (backend + care_fe) on the Raspberry Pi
**lumine**, without Docker or Kubernetes. This is a hand-off document: an agent
picking this up should read it top to bottom, check the **Status log** at the
end, and continue from the first unfinished phase. Update the status log as
you go.

> Repo rules still apply (`AGENTS.md`): atomic changes, never print secrets,
> ask before destructive / live-impacting actions (flashing disks, EEPROM,
> reboots). When functionality lands, it also needs a real docs page
> (`docs/care-box.md`), `justfile` recipes and Gatus/Homepage entries; this
> file is the plan, not the docs.

## Goal

- CARE backend + care_fe, **same branches and configuration as avocado**
  (`k8s/care/care.yaml`, `docs/care.md`) **minus everything TeleICU**
  (no gateway, devices plugs, devices MFE, mock devices).
- Public at `https://care-box.rithviknishad.dev` through a Cloudflare tunnel,
  **one origin, path-routed** like avocado's `care` Ingress:
  `/api/*` → backend, `/care-uploads/*` and `/care-facility/*` → VersityGW,
  `/*` → care_fe static files (SPA fallback to `index.html`).
- Plain systemd services: PostgreSQL, Redis, nginx, gunicorn (API), celery
  worker, celery beat, VersityGW (S3 over a local directory), cloudflared.
- Boots from an SSD; no SD card needed. **Deferred** (see Phase 0): for now
  everything runs on the SD card.

## Host facts (probed 2026-10-06)

| | |
|---|---|
| Access | `ssh rithviknishad@lumine.local`, passwordless sudo |
| Board | Raspberry Pi 5 Model B Rev 1.1, **2 GB RAM**, 4 cores |
| OS | Raspberry Pi OS = Debian 13 trixie arm64, kernel 6.18 (`+rpt-rpi-2712`), freshly imaged with rpi-imager (cloud-init `nocloud`) |
| Python | 3.13.5 (matches CARE's Pipfile `python_version = "3.13"`) |
| Network | `eth0` DHCP via NetworkManager, `192.168.165.244/24`, gw `192.168.165.1` (same LAN as avocado `192.168.165.202`); mDNS via avahi; wlan0 down |
| Storage | only the SD card `mmcblk0` 58 GB (`p1` vfat `/boot/firmware`, `p2` ext4 `/`, root `PARTUUID=11c03eb1-02`); zram swap 2 GB |
| SSD | **not detected**: no NVMe, nothing on USB, external PCIe `pcie@1000110000` is `disabled`, no HAT EEPROM |
| Bootloader | EEPROM 2026-05-11 (update to 2026-05-26 available); `BOOT_ORDER=0xf461` (SD → NVMe → USB → retry), `NET_INSTALL_AT_POWER_ON=1` |
| Kernel cmdline | `/proc/cmdline` has `cgroup_disable=memory`, **prepended by the firmware** (it is not in `cmdline.txt`); systemd `MemoryMax=` is ignored until re-enabled |
| Power | EXT5V 5.11 V, `usb_max_current_enable=1`, not throttled |
| Installed | nothing relevant: no nginx/postgres/redis/cloudflared/git/node |

## Decisions (all answered by the user, 2026-10-06)

1. **OS**: stay on **Raspberry Pi OS** + plain systemd units (no NixOS, no
   Docker, no k8s). Config lives in this repo under `lumine/` and is applied
   to the box.
2. **SSD**: **deferred**. Build everything on the SD card now; Phase 0 is
   picked up later. Keep data paths (`/var/lib/postgresql`, `/var/lib/care`,
   `/opt/care`) plain so the later SD → SSD clone is a straight copy.
3. **ABDM plug**: **include it** (backend plug + the ABDM MFE at
   `/mfe-plugs/abdm/`, care_fe built with
   `REACT_MFE_REGISTERED_COMPONENTS=AddFacilitySheet`, same pinned care-abdm
   sha as avocado's `k8s/care/additional-plugs.json`).
   **Do NOT run `abdm_register_bridge_url` on care-box** without asking the
   user first: ABDM has one bridge URL per client id, and registering
   care-box takes callbacks away from avocado (`docs/care.md` → ABDM).
   Set `ABDM_CALLBACK_BASE_URL=https://care-box.rithviknishad.dev` anyway.
4. **Refs**: **track the branches** (follow their heads on each deploy, no
   sha pin): backend `rithviknishad/care@rithviknishad/bodhi/ENG-737-test-fixtures`,
   SPA `ohcnetwork/care_fe@bodhi/questionnaire-actions` (= avocado's, see
   `docs/care.md` → "Currently deployed"). Record the deployed sha somewhere
   inspectable (e.g. `/opt/care/backend/REVISION`) so "what's running" is
   answerable. The care-abdm plug stays sha-pinned (both halves in lockstep).
5. **Data**: **demo fixtures** (`load_fixtures`), then change the weak
   `admin`/`admin` password (the secret has `BOX_ADMIN_PASSWORD` for this).
6. **Django admin**: **tailnet/LAN only**, never on the public origin (the
   SPA owns `/admin/*`). E.g. a second nginx `server` on `lumine:8000` (or
   gunicorn's port) bound so it's reachable via `tailscale0`/LAN only; it is
   NOT in the cloudflared ingress.
7. **Tailscale**: **done** (see status log). lumine = `100.67.15.72`,
   MagicDNS name `lumine` / `lumine.orthrus-bass.ts.net`.
8. **Email**: avocado's **Mailpit** over the tailnet: host `avocado`
   (`100.123.72.40`), port `1025`, user `csaas`, AUTH required, **no TLS**
   (`EMAIL_USE_TLS`/`EMAIL_USE_SSL` off). Password = `EMAIL_PASSWORD` in the
   secret. Check CARE's settings for the exact env var names
   (`EMAIL_HOST_PASSWORD` etc., `config/settings/base.py`) and map
   accordingly. Verified reachable from lumine: TCP `avocado:1025` OK.
9. **Repo layout**: `lumine/` (nginx site, systemd units, provisioning
   script, env template, this plan) + `docs/care-box.md` + `box-*` recipes
   in the `justfile`.

## Working ON lumine (agent running on the Pi)

> **Superseded 2026-10-07 (after Phase 5):** avocado is now the control
> plane. The repo clone, sops and agent tooling are gone from the Pi, the
> `box-*` recipes run on avocado/the Mac over SSH, and lumine is no longer a
> sops recipient (`docs/care-box.md` → Control plane). Kept for the record of
> how Phases 1-5 were done.

The implementing agent runs on lumine itself, in the repo clone at
`~/systems.nix`. Things that differ from working on avocado/the Mac:

- **No Nix on the box**: no devshell, `nix fmt` or `just eval`. This work
  shouldn't touch any `.nix` file; if it does, leave validation of that
  part to avocado. Install the tools needed here with apt / release binaries:
  `git` (installed), `just` (trixie has it), `sops` (GitHub release
  `sops-v3.13.1.linux.arm64`, same version as avocado's devshell; verify the
  checksum), `awscli` if wanted for bucket bootstrap.
- **Secrets decrypt on the box with its SSH host key** (lumine is a sops
  recipient as `ssh-ed25519 ...`, see `.sops.yaml`). As root:
  `sudo env SOPS_AGE_SSH_PRIVATE_KEY_FILE=/etc/ssh/ssh_host_ed25519_key sops -d ...`
  - `secrets/care-box.enc.env` (dotenv) holds: `DJANGO_SECRET_KEY`,
    `JWKS_BASE64`, `BUCKET_KEY`, `BUCKET_SECRET`, `ABDM_CLIENT_ID`,
    `ABDM_CLIENT_SECRET`, `EMAIL_PASSWORD`, `BOX_ADMIN_PASSWORD`. There is
    **no Postgres password** in it: prefer peer auth over the unix socket
    (`DATABASE_URL=postgres:///care` as the `care` OS user), so none is
    needed; add one only if that doesn't work out. Add new keys with
    `sops set` / `sops edit` as root; never echo values.
  - `secrets/lumine-cloudflared.json` (sops **binary**: `--input-type binary
    --output-type binary`) = credentials of tunnel `lumine`
    `1e284975-9221-4b79-8242-0722c96294ed`.
  - Decrypted copies go only to root-owned `0600` files outside the repo
    (`/etc/care/care.env`, `/etc/cloudflared/<tunnel-id>.json`).
- **No kubeconfig / k8s access from lumine.** The Gatus probe and Homepage
  tile (Phase 6) are edits in `k8s/` that must be **applied from avocado**
  (`kubectl kustomize` to validate, then the usual deploy recipe). Write the
  edits here; ask the user to deploy them from avocado.
- **care_fe can't be built here** (Vite needs ~4 GB; lumine has 2 GB). The
  SPA and the ABDM MFE are static, arch-independent builds: make a `just`
  recipe that the **user runs on avocado** (it has docker, `.build/`, and
  SSH to lumine over the tailnet), builds both with the care-box origin baked
  in, extracts the files from the images, and rsyncs them to lumine.
- DNS/tunnel routing needs the Cloudflare login cert, which stays on avocado
  (`~/.cloudflared/cert.pem`). Already done for `care-box` (status log).
- Destructive / live-impacting steps still need the user's explicit OK:
  reboots (incl. the cgroup change below), wiping data, EEPROM.
- **Memory cgroup**: the firmware prepends `cgroup_disable=memory` to the
  kernel command line (see `/proc/cmdline`; it is *not* in
  `/boot/firmware/cmdline.txt`), so `MemoryMax=` is ignored. Appending
  `cgroup_enable=memory` to `cmdline.txt` (single line!; the later argument
  wins) + a reboot is needed before the per-unit memory limits mean
  anything. Ask before rebooting.

## Phase 0: SSD + boot from SSD  (DEFERRED: user will revisit later)

Skip this phase for now; start at Phase 1 on the SD card. Note that
`dtparam=pciex1` is still in `/boot/firmware/config.txt` (PCIe link is
down; harmless, it only probes an empty port at boot).

Goal: the Pi boots from the SSD, comes back at the same address after every
reboot, and the SD card can be removed. **Every step that writes the SSD,
changes the EEPROM or reboots needs explicit user confirmation.**

### 0.1 Get the SSD detected
- **NVMe on an M.2 board on the PCIe ribbon (non-HAT+, no EEPROM):** add
  `dtparam=pciex1` under `[all]` in `/boot/firmware/config.txt` (optionally
  `dtparam=pciex1_gen=3`; Gen 3 isn't officially certified, so start without
  it), then reboot. The SD card still boots, so this can't lose the box.
  A HAT+ board is detected automatically; nothing to add.
- **USB SSD:** plug into a blue USB 3 port. No config needed.
- Verify: `lsblk`, `lspci`, `ls -l /dev/disk/by-id/`, `dmesg | grep -i nvme`;
  check health with `smartctl -a` (`smartmontools`) / `nvme smart-log`
  (`nvme-cli`). Check whether the drive already holds data before wiping.

### 0.2 Clone the running SD onto the SSD (the SD stays untouched)
Rsync-based clone, so the SSD gets its **own** disk identifier/PARTUUIDs
(a raw `dd` would duplicate PARTUUIDs and make `root=PARTUUID=` ambiguous
while both are attached):
1. Partition the SSD like the SD: `p1` 512 MB vfat (boot), `p2` ext4 using
   the rest of the disk (`sfdisk`, msdos label like the SD).
2. `mkfs.vfat -F 32 -n bootfs` / `mkfs.ext4 -L rootfs`; mount them under
   `/mnt/ssd` and `/mnt/ssd/boot/firmware`.
3. `rsync -aHAXx --numeric-ids` `/` → `/mnt/ssd/` and `/boot/firmware/` →
   `/mnt/ssd/boot/firmware/` (`-x` keeps it to one filesystem; exclude
   nothing else, as `/proc`, `/sys`, `/dev`, `/run` and `/tmp` are separate mounts).
4. On the **SSD copy only**: replace the old PARTUUIDs in
   `/mnt/ssd/boot/firmware/cmdline.txt` (`root=`) and `/mnt/ssd/etc/fstab`
   with the SSD's (`blkid`), and append `cgroup_enable=memory` to
   `cmdline.txt` (the firmware injects `cgroup_disable=memory` ahead of it);
   it's a single line, so keep it a single line.
5. Double-check before any reboot: `blkid` of the SSD partitions matches
   every PARTUUID referenced by the SSD's `cmdline.txt` and `fstab`.

### 0.3 Bootloader
- Write the EEPROM config with `rpi-eeprom-config` and apply it with
  `sudo rpi-eeprom-config --apply <file>`; this also moves to the latest
  bootloader image. Applied at the next reboot.
- NVMe: `BOOT_ORDER=0xf416` (NVMe → SD → USB → retry) and, for a non-HAT+
  M.2 board, `PCIE_PROBE=1`. USB SSD: `BOOT_ORDER=0xf614`
  (USB → SD → NVMe → retry). Keep `BOOT_UART=1`.
- Keeping SD as the second entry means removing the SSD = boot from SD again.

### 0.4 Reboot onto the SSD, keeping the connection
Why the box should come back as-is: the clone keeps hostname, SSH host keys,
the user + authorized_keys and the NetworkManager DHCP setup, and the NIC MAC
doesn't change → same DHCP lease `192.168.165.244` and same `lumine.local`.
cloud-init has the same instance id (`rpi-imager-1785821739362`), so it
won't re-run.

Failure mode: if the SSD boot partition loads but the root fs can't be found,
the kernel waits forever (`rootwait`); the bootloader does not fall back.
Recovery is physical: power off, disconnect the SSD (or pull its ribbon),
power on → boots the untouched SD. Tell the user this before rebooting.

After the reboot, verify:
`findmnt /` and `findmnt /boot/firmware` are on the SSD, the EEPROM version
and `BOOT_ORDER` are new (`rpi-eeprom-update`, `rpi-eeprom-config`), the
memory cgroup is enabled (`grep memory /sys/fs/cgroup/cgroup.controllers`),
and `systemctl --failed` is empty. Optionally grow-check `df -h /`.

### 0.5 Drop the SD card
User powers off (`sudo poweroff`), removes the SD, powers on; confirm the box
comes back over SSH. Keep the SD card as a cold rescue image (don't reuse it
until Phase 1 is done).

## Phase 1: Base system
- Tailscale: **done** (official apt repo, `tailscaled` enabled).
- `apt full-upgrade`; install `postgresql-17`, `redis` (or valkey, whatever
  trixie ships), `nginx`, `git`, `gettext` (compilemessages), `libmagic1`
  (python-magic), pango/cairo libs for weasyprint, `libpq-dev` +
  `build-essential` (`psycopg[c]`), `rsync`.
- cloudflared from Cloudflare's apt repo; VersityGW arm64 release binary at
  the **same version as avocado (v1.8.0)**.
- System user `care`; code + venv under `/opt/care`, data (VersityGW) under
  `/var/lib/care`.
- Postgres tuned for 2 GB (e.g. `shared_buffers=128MB`, `max_connections≈30`).

## Phase 2: Backend
- Clone the backend ref; build a venv with the Pipfile's packages (use the
  `pipenv` lock → requirements, or `pipenv install --deploy` into the venv);
  install the plugs the same way upstream's `install_plugins.py` does.
  `ADDITIONAL_PLUGS` = avocado's **minus** the three TeleICU plugs (so just
  `abdm`, see decision 3); build arg and runtime env must match.
- Env file (`/etc/care/care.env`, root-owned, `0600`, systemd `EnvironmentFile=`)
  modeled on avocado's `care-backend-env` ConfigMap, with
  `https://care-box.rithviknishad.dev` as `CURRENT_DOMAIN`, `BACKEND_DOMAIN`,
  `BUCKET_EXTERNAL_ENDPOINT`, CORS/CSRF origins;
  `DJANGO_SETTINGS_MODULE=config.settings.deployment`,
  `DJANGO_SECURE_SSL_REDIRECT=false`, `BUCKET_PROVIDER=MINIO`,
  `BUCKET_REGION=ap-south-1` (**SigV4-only region**, see docs/care.md),
  `BUCKET_ENDPOINT=http://127.0.0.1:7070`, buckets `care-uploads` /
  `care-facility`, local postgres/redis URLs.
- `collectstatic` + `compilemessages` **once per deploy** (not every start;
  avocado only runs it on start to reproduce prod).
- systemd units (mirror upstream's scripts):
  - `care-beat`: `migrate` → `compilemessages` → `sync_permissions_roles` →
    `sync_valueset` → `celery beat` (beat owns migrations, as upstream does).
  - `care-api`: gunicorn `config.wsgi:application`,
    `--config python:config.gunicorn`, bind `127.0.0.1:9000`, 2 workers, `--preload`.
  - `care-worker`: `celery worker`, concurrency 1.
  - `MemoryHigh`/`MemoryMax` per unit (needs `cgroup_enable=memory` from Phase 0).

## Phase 3: Frontend
- **Build care_fe on avocado, not on the Pi** (the Vite build needs ~4 GB RAM;
  the output is architecture-independent). Same as `just care-fe-image` but
  with `.env.local` `REACT_CARE_API_URL=https://care-box.rithviknishad.dev`
  (+ `REACT_MFE_REGISTERED_COMPONENTS=AddFacilitySheet` only if ABDM is in).
  Rsync the build output to the Pi (e.g. `/opt/care/fe/<sha>` + a `current`
  symlink so a bad build can be rolled back).

## Phase 4: Storage, nginx, tunnel
- VersityGW posix backend over `/var/lib/care/s3` (ext4 supports `user.*`
  xattrs), root creds = `BUCKET_KEY`/`BUCKET_SECRET`, region `ap-south-1`,
  health `/health`. Create buckets like avocado's `versitygw-buckets` Job:
  `care-facility` gets anonymous `s3:GetObject`, `care-uploads` stays private
  (use `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` with aws-cli).
- nginx site: `/api/` → `127.0.0.1:9000`; `/care-uploads/`, `/care-facility/`
  → `127.0.0.1:7070` with **`proxy_set_header Host $host`** (SigV4 signs
  Host); `/` → care_fe dist with `try_files $uri /index.html`;
  `client_max_body_size 100m` (Cloudflare free-plan cap). Optionally an exact
  `location = /ping/` → backend for health probes.
- Cloudflare: a **new dedicated tunnel `lumine`** (independent of avocado),
  credentials sops-encrypted (`secrets/lumine-cloudflared.json`, done),
  ingress `care-box.rithviknishad.dev` → `http://localhost:80`, default
  `http_status:404`. The DNS route is **done** (CNAME → tunnel). Give the unit the same "retry forever" restart
  policy as avocado's (`modules/cloudflared.nix` explains the outage it fixes).
- Verify through Cloudflare: SPA 200, `/api/v1/plug_config/` 200,
  presigned PUT/GET 200 on both buckets, anonymous GET 403 on `care-uploads`
  and 200 on `care-facility`, presigned URLs carry `X-Amz-Algorithm`.

## Phase 5: Secrets + seeding
- **Fresh** secrets (not avocado's) live in `secrets/care-box.enc.env`
  (exists; contents listed under "Working ON lumine"). Nothing to add
  unless Postgres peer auth doesn't work out.
  A `just` recipe on lumine decrypts it with the host key and renders
  `/etc/care/care.env` (root, `0600`) = non-secret settings (from a
  committed template in `lumine/`) + the secrets; plaintext never touches
  the repo tree or the chat.
- Seed as decided (demo: `pip install Faker==38.2.0` +
  `DJANGO_DEBUG=true python manage.py load_fixtures`, then **change the
  `admin`/`admin` password**; production: `load_govt_organization_csv` +
  `createsuperuser` run by the user).

## Phase 6: Operations
- Nightly `pg_dump -Fc` via a systemd timer on the SSD (14-day prune), **and
  rsync the dumps + the VersityGW directory to avocado**: a second machine,
  so actual disaster recovery.
- Gatus (`k8s/monitoring/gatus.yaml`, new group e.g. `ohcnetwork/care-box`):
  SPA `/`, an API endpoint, cert expiry; bump the gatus `checksum/config`.
- Homepage tile: a static entry in `services.yaml` in
  `k8s/homepage/homepage.yaml` (no Ingress here); bump its `checksum/config`.
- `just box-*` recipes (deploy, logs, manage, status, secrets) and
  `docs/care-box.md`; link it from `docs/care.md`.

## Memory budget (2 GB)
| | approx. |
|---|---|
| postgres (tuned) | 200 MB |
| gunicorn, 2 workers + `--preload` | 400 MB |
| celery worker, concurrency 1 | 300 MB |
| celery beat | 180 MB |
| redis + nginx + versitygw + cloudflared | 100 MB |
| OS | 200 MB |
| **total** | **~1.4 GB** |

Spikes: first `migrate` + `sync_valueset`, and weasyprint PDF rendering.
zram swap (2 GB) is the safety net; consider folding beat into the worker
(`celery worker -B`) if memory is tight.

## Status log
- 2026-10-06: probed host (facts above). No SSD detected; external PCIe port
  disabled. Plan written. Waiting for the user to say what SSD they have / attach it.
- 2026-10-06: user: NVMe on an M.2 board, physically attached. Step 0.1 done
  on the SD: appended `dtparam=pciex1` under the final `[all]` of
  `/boot/firmware/config.txt` (backup: `config.txt.bak-pre-pciex1`), rebooted
  (came back fine at the same address). Result: `pcie@1000110000` now probes
  but the kernel logs **`link down`**, so no NVMe device appeared. Likely
  physical (ribbon seating/orientation, board power, drive seating) or a
  drive/board incompatibility. Waiting for the user to check the hardware
  (power off before reseating the ribbon).
- 2026-10-06: user **deferred the SSD**; build on the SD card for now.
  Decisions 1-9 answered (see Decisions). The implementation will be done by
  an agent running on lumine itself.
- 2026-10-06 (from avocado):
  - **Tailscale installed + joined**: official apt repo (trixie),
    `tailscale 1.102.5`, `tailscale up --hostname=lumine` (interactive
    login, user's account) → `100.67.15.72`. Defaults kept (MagicDNS on:
    `/etc/resolv.conf` → `100.100.100.100`); public names, `github.com`,
    `pypi.org`, `region1.v2.argotunnel.com` and `avocado` all resolve.
    SSH over the tailnet presents the same host key as `lumine.local`.
    lumine ↔ avocado direct over the LAN; `avocado:1025` (Mailpit) reachable.
  - **sops**: lumine added as a recipient (`&lumine`, its SSH host ed25519
    key) for `secrets/care-box.enc.env` and `secrets/lumine-cloudflared.json`
    only; both re-keyed (`sops updatekeys`). Neither file is committed yet.
  - **DNS**: `cloudflared tunnel route dns lumine care-box.rithviknishad.dev`
    → CNAME to tunnel `1e284975-9221-4b79-8242-0722c96294ed`. It serves a
    Cloudflare "tunnel offline" error until cloudflared runs on lumine.
  - **Repo copied to lumine** at `~/systems.nix` (git bundle of `main` +
    the uncommitted files above; the gitignored plaintext secret files on
    avocado were deliberately NOT copied). `git` installed on lumine.
  - **Next: Phase 1** (base packages), on the SD card.
- 2026-10-07 (agent on lumine): **Phase 1 done** (base system, SD card).
  - `lumine/provision.sh` (`just box-provision`): idempotent, a re-run is
    a no-op. Tuning in `lumine/postgresql/care-box.conf`. Upgrades are a
    separate, deliberate `just box-upgrade`.
  - `apt full-upgrade` (135 pkgs): kernel 6.18.50 + firmware installed but
    **only active after the next reboot** (still running 6.18.34).
    `rpi-eeprom` 28.33 keeps the boot-time auto-update minimum at 2025-05-08,
    so `rpi-eeprom-update.service` won't flash (bootloader stays 2026-05-11).
    `config.txt`, `cmdline.txt` and the EEPROM config are byte-identical.
  - Installed: postgresql-17 17.11, redis-server 8.0.2, nginx 1.26.3
    (Debian's default site disabled, so nothing listens on :80 yet),
    cloudflared 2026.10.0 (Cloudflare apt repo, signing-key fingerprint
    pinned; not enabled), sops 3.13.1 + VersityGW 1.8.0 in `/usr/local/bin`
    (sha256 pinned in the script), just 1.40, awscli 2.23.6, the
    Dockerfile's build deps plus `python3-venv`/`python3-dev`, weasyprint
    libs (DejaVu fonts come in as deps).
  - `care` system user (home `/opt/care`); `/opt/care` care 755,
    `/var/lib/care` root 755, `/etc/care` root 700.
  - Postgres: `shared_buffers=128MB`, `effective_cache_size=512MB`,
    `work_mem=4MB`, `max_connections=30`, `jit=off`,
    `checkpoint_timeout=15min`. Role `care` (not superuser) owns db `care`;
    peer auth over the socket works, and `CREATE EXTENSION pg_trgm` (the
    only extension CARE's migrations create; trusted) works as `care`.
  - Only sshd/tailscaled listen beyond loopback; postgres + redis are
    loopback-only. sops decrypts both lumine secrets with the host key.
  - Findings: (1) the memory cgroup is disabled by the firmware, not
    `cmdline.txt` (corrected above). (2) The Cursor server + agents take
    ~850 MB RSS while a session is open; ~970 MB available after Phase 1.
    (3) `config.settings.deployment` hard-codes `EMAIL_USE_TLS = True`, and
    Mailpit is plain SMTP, so mail fails at STARTTLS as configured; CARE's
    vars are `EMAIL_HOST/PORT/USER/PASSWORD/FROM` (decide in Phase 2).
    (4) deployment settings set Secure session/CSRF cookies, so Django
    admin over plain `http://lumine:8000` can't log in (decide in Phase 4).
  - **Next: Phase 2** (backend).
- 2026-10-07: **Phase 2 done** (backend), deployed
  `rithviknishad/care@82ae319bf02e` (branch head) + `abdm@969a278`.
  - User decisions: (a) email = a settings module shipped from
    `lumine/care/care_box_settings.py` (`config.settings.care_box` =
    deployment + `EMAIL_USE_TLS` from env); (b) the cgroup/kernel reboot
    happens **after Phase 4**, as a "comes back on boot" test.
  - The env rendering planned for Phase 5 landed here (the backend can't
    start without it): `just box-env` renders `/etc/care/care.env` (root
    0600, 36 values; `BOX_*` keys excluded) and verifies through systemd's
    own parser that every value round-trips (key names only). `just
    box-secrets` edits the sops file with the host key.
  - `just box-deploy` (`lumine/care/deploy-backend.sh`) builds releases
    under `/opt/care/backend/<sha12>-<cfg8>` + `current` symlink, mirroring
    the Dockerfile (venv, `pipenv install --deploy`, `install_plugins.py`),
    with collectstatic (193 copied / 905 post-processed, same as avocado
    without token_display) + compilemessages + compileall once per build.
    `REVISION` + `build.env` (the pip-installed `ADDITIONAL_PLUGS`, loaded
    by the units) per release. Plugs = avocado's JSON minus TeleICU, derived
    at deploy time. Re-run = "up to date"; keeps 2 old releases.
  - Units: `care.target` → `care-beat` (migrate, sync_permissions_roles,
    sync_valueset as ExecStartPre; schedule in `/var/lib/care/beat`),
    `care-api` (gunicorn 127.0.0.1:9000, 2 workers, `--preload`),
    `care-worker` (concurrency 1). API + worker are ordered after beat's
    start job, so they only start on a migrated schema. Hardened
    (`ProtectSystem=strict`, ...). `box-restart/status/logs/manage` recipes.
  - Verified: `/ping/` 200 `{"status": "OK"}`, `/api/v1/plug_config/` 200,
    `/api/abdm/health` 200 (plug loaded), `abdm` in INSTALLED_APPS, runtime
    plugs == build plugs, peer-auth DB, celery `inspect ping` pong + a task
    round-trip SUCCESS, beat dispatched `abdm retry share items` on schedule,
    `sendtestemail` accepted by Mailpit (plain SMTP + AUTH). Warm requests
    ~1.5 ms.
  - Memory (`free -h` sampled every 5 s): first migrate + sync_valueset
    took ~2.5 min with ≥ 810 MB available; the peak was the pip build
    (358 MB available, 562 MB zram swap). Idle PSS: API 208 MB, worker
    171 MB, beat 118 MB, postgres 30 MB; Cursor server + agents ~495 MB.
    Limits set from that (API 450M/650M, worker 400M/600M, beat 350M/600M,
    High/Max), not enforced until the cgroup reboot.
  - Found + fixed: with `--preload`, Django's
    `disable_existing_loggers: True` silenced gunicorn (no access log, no
    WORKER TIMEOUT); `care_box.py` re-enables its two loggers. Celery's
    "ready"/"beat: Starting" lines are suppressed the same way upstream
    (left as-is, same as avocado).
  - **Next: Phase 3** (frontend, built on avocado).
- 2026-10-07: **Phase 3 done** (frontend). `just box-fe` (runs on
  avocado; the user ran lumine's justfile there with `just -f ... -d .`,
  nothing committed yet) built care_fe `bodhi/questionnaire-actions@8c4edae`
  with `.env.local` = care-box origin + `AddFacilitySheet`, and the ABDM MFE
  from `k8s/care/abdm-fe` at `969a278` (identical to avocado's; it bakes
  in no origin). Shipped as root-owned 644 files to
  `/opt/care/fe/8c4edae0c635-a2396882/` and
  `/opt/care/abdm-fe/969a27839c02-eb5d3de9/`, each `{html/, REVISION}` (so
  build metadata stays out of the web root) + a `current` symlink; keeps two
  old builds. Verified on lumine: the origin is in the bundle,
  `careapi.ohc.network` (upstream's `.env` default) is nowhere,
  `AddFacilitySheet` is registered, and the MFE's `remoteEntry.js` uses the
  `/mfe-plugs/abdm/` base. Not served yet (nginx is Phase 4).
  - **Next: Phase 4** (VersityGW + buckets, nginx, tunnel).
- 2026-10-07: **Phase 4 done**: **care-box is public** at
  `https://care-box.rithviknishad.dev`.
  - User decision: **no Django admin** for now (not routed anywhere; the
    SPA owns `/admin/*`). If needed later: SSH tunnel to `127.0.0.1:9000`
    (documented), since Secure cookies rule out plain http on the LAN.
  - Secrets: `lumine/care/render-env.sh` → `lumine/render-secrets.sh`
    (`just box-env` → `just box-secrets-render`), now one root-0600 file
    per consumer: `/etc/care/care.env`, `/etc/care/versitygw.env` (only the
    gateway root creds = BUCKET_KEY/SECRET), `/etc/cloudflared/<id>.json`.
    Restarts consumers of changed files.
  - `versitygw.service` (static user `versitygw`, `127.0.0.1:7070`, posix
    over `/var/lib/care/s3` 0750, `VGW_REGION=ap-south-1`) + `just
    box-buckets` (= avocado's Job minus `teleicu-gateway`; idempotent).
  - nginx `lumine/nginx/care-box.conf` on 127.0.0.1:80 (provision runs
    `nginx -t`, restores the old site on failure): routes as in docs/care-box.md;
    care_fe's headers/caching for `/`, abdm-fe's rules for the MFE, `Host`
    kept + streaming for the buckets, `(/|$)` so bucket-level paths hit the
    gateway.
  - `cloudflared-lumine.service` (DynamicUser, `LoadCredential=`,
    `--no-autoupdate`, `StartLimitIntervalSec=0` + `RestartSec=10`): 4
    QUIC connections (maa04/bom11/bom12). Ingress via 127.0.0.1 (nginx is
    IPv4-loopback only).
  - Verified through Cloudflare: SPA + client routes + assets 200,
    `/api/v1/plug_config/` + `/api/abdm/health` 200, `remoteEntry.js` 200
    `no-cache`, `/admin/` = SPA; with CARE's own client config presigned
    PUT/GET 200 on both buckets, SigV4 (`X-Amz-Algorithm`), Content-Type
    round-trips (xattrs), anonymous GET 403 uploads / 200 facility, LIST 403
    both (test objects deleted). Edge cert: Universal SSL
    `*.rithviknishad.dev`, valid to 2026-12-29.
  - Memory: versitygw ~23 MB, cloudflared ~37 MB, nginx ~5 MB PSS; limits
    128M/256M on the first two. API warmed up to ~309 MB PSS.
  - Found: CARE's login rate limit keys on REMOTE_ADDR = 127.0.0.1 here (all
    clients share one bucket; same on avocado via Traefik), left as is,
    documented. `Python-urllib` UA gets Cloudflare 1010 (requests/curl ok).
  - **Reboot test (approved: "after Phase 4")**: appended
    `cgroup_enable=memory` to `/boot/firmware/cmdline.txt` (backup:
    `cmdline.txt.bak-pre-cgroup`) and scheduled a reboot, which also
    activates kernel 6.18.50. **Post-reboot checks still to do**: `uname -r`
    = 6.18.50; `memory` in `/sys/fs/cgroup/cgroup.controllers`;
    `systemctl --failed` empty; care.target/versitygw/cloudflared-lumine
    active; `memory.max` of the care units = their `MemoryMax=`; the public
    checks above; `free -h` without an agent session. Recovery if it
    doesn't boot: SD card into another machine, restore
    `cmdline.txt.bak-pre-cgroup`.
  - **Next: Phase 5** (seed demo fixtures, rotate `admin`, register the ABDM
    plug_config).
- 2026-10-07: **reboot test passed** (closes Phase 4). Kernel
  6.18.50+rpt-rpi-2712; `/proc/cmdline` has `cgroup_disable=memory` (firmware)
  then `cgroup_enable=memory` (ours), and `memory` is in
  `cgroup.controllers`, so every unit's `memory.high`/`memory.max` now
  equals its `MemoryHigh=`/`MemoryMax=`. `systemctl --failed` empty, no
  errors this boot; EEPROM still 2026-05-11. Boot order as designed:
  versitygw + tunnel up first (4 connections within 2 s), beat's migrate ("No
  migrations to apply") took 16 s, API + worker started the instant beat's
  start job finished. Public checks all 200/403 as before. Memory: the whole
  stack + OS ~860 MB PSS; the reconnected Cursor session another ~660 MB,
  so ~1.1 GB is available with no agent connected.
- 2026-10-07: **Phase 5 done** (seeding).
  - `just box-seed-demo` (`lumine/care/seed-demo.sh`): Faker 38.2.0 (pin
    read from the release's `Pipfile.lock`, deps constrained to the lock)
    into a throwaway `/tmp` dir on `PYTHONPATH` (release venv untouched),
    `load_fixtures` with `DJANGO_DEBUG=true` for that process only (the
    fixture context checks `settings.DEBUG`), then `admin`'s password
    <- `BOX_ADMIN_PASSWORD` via a pipe into `manage.py shell -c` (never argv/env).
    Idempotent: skips the load when `care-admin` exists (a re-load duplicates
    data and resets admin to admin/admin); re-run printed "already set".
    `manage.sh` gained `--setenv=K=V` (non-secret one-offs only).
  - Seeded in ~30 s: 2 facilities, 10 patients, 10 encounters, 10 users,
    DB 31 MB; min 297 MB available / 412 MB swap with the agent connected.
  - `just box-register-abdm` (ORM upsert + clears the cached plug list):
    created, re-run "unchanged".
  - Verified through Cloudflare: admin/admin 401; admin + BOX_ADMIN_PASSWORD
    200 (superuser); demo `care-doctor` 200; public plug_config lists abdm at
    the care-box MFE URL; `/api/abdm/gateway/status` 200 `ok: true`.
  - **Not done, on purpose:** `abdm_register_bridge_url` (not even
    `--dry-run`); ABDM callbacks still go to avocado. Demo users keep the
    public `Ohcn@123` (decision 5 rotates only admin).
  - **Next: Phase 6** (backups + offsite copy, Gatus, Homepage, finish docs).
- 2026-10-07 (on avocado): Phases 1-5 committed from the Pi's clone
  (`eeabdbd`). **avocado is the control plane** from here on:
  - `box-*` recipes run on avocado/the Mac and ssh to `rithviknishad@lumine`;
    `just box-sync` ships `lumine/` (+ `additional-plugs.json`,
    `SYSTEMS_NIX_REVISION`) to root-owned `/usr/local/lib/care-box`.
  - Secrets are decrypted on the control plane and streamed over SSH stdin;
    `&lumine` removed from `.sops.yaml` and both files re-keyed. Provision
    removed sops + `just` from the box.
  - New: `box-start`/`box-stop` (+ wait for gunicorn), `box-offline`/
    `box-online` (tunnel), `box-health`, `box-ssh`. Verified from avocado:
    provision (no drift), secrets-render (unchanged), deploy (up to date),
    seed-demo (idempotent), `box-manage` quoting, stop -> health fails ->
    start (16 s) -> health passes.
  - Pinned lumine's host key on avocado (`modules/care-box.nix`).
- 2026-10-07: **backups** (Phase 6, revised: no on-box dumps, the SD card
  isn't where copies should live). avocado pulls nightly with a forced-command
  key (`lumine/backup/`, `care-backup` user on the Pi) into
  `/var/lib/care-box-backups`: `care.dump` + `s3/` (xattrs) per snapshot,
  `--link-dest` dailies, 7-day retention, textfile metrics +
  `CareBox*` alerts. `just box-backup` / `box-backups`. Tested the script by
  hand (2 runs, prune, scratch-DB restore) and the forced command's
  refusals; the service itself runs once avocado is deployed.
- 2026-10-07: **metrics.** Debian's node/postgres/redis/nginx/process
  exporters + cloudflared `metrics:` + `rpi-metrics.timer` (vcgencmd:
  temps, throttle bits, clocks, PMIC rails/power), all from `lumine/metrics/`;
  ports tailnet-only via our own nft table (LAN verified blocked). avocado:
  `VMStaticScrape` (node target as `job=node-exporter` for stock
  alerts/dashboards), `care-box-vmrules.yaml`, "care-box (lumine)"
  dashboard (71 panels). All 119 PromQL expressions parse-checked against
  VictoriaMetrics.
