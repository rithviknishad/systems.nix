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
| Kernel cmdline | includes `cgroup_disable=memory` (systemd `MemoryMax=` is ignored until re-enabled) |
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
- **Memory cgroup**: the SD's `/boot/firmware/cmdline.txt` still has
  `cgroup_disable=memory`, so `MemoryMax=` is ignored. Replacing it with
  `cgroup_enable=memory` (single line!) + a reboot is needed before the
  per-unit memory limits mean anything. Ask before rebooting.

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
   with the SSD's (`blkid`), and in `cmdline.txt` replace
   `cgroup_disable=memory` with `cgroup_enable=memory`; it's a single line,
   so keep it a single line.
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
  `ADDITIONAL_PLUGS` = avocado's **minus** the three TeleICU plugs (plus or
  minus `abdm`, see decision 2); build arg and runtime env must match.
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
