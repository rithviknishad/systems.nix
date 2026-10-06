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
- Boots from an SSD; no SD card needed.

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

## Decisions

Answered:
- Platform: Raspberry Pi OS + systemd units (not NixOS, not containers), as
  proposed. Re-confirm before Phase 1 if in doubt.
- Phase 0 (SSD boot) comes before anything else.

Still open (ask the user at the start of Phase 1, all at once):
1. **OS**: stay on Raspberry Pi OS with config in this repo applied over SSH
   (recommended) vs NixOS via `nixos-raspberrypi` (`nixitup` skill).
2. **ABDM plug**: include or not. ABDM has **one bridge URL per client id**,
   so registering care-box would take callbacks away from avocado.
   Recommendation: leave it out (or include it but never register the bridge).
3. **Refs**: same as avocado (`docs/care.md` → "Currently deployed"):
   backend `rithviknishad/care@rithviknishad/bodhi/ENG-737-test-fixtures`,
   SPA `ohcnetwork/care_fe@bodhi/questionnaire-actions`. Pin to commit SHAs or
   track the branches?
4. **Data**: demo (`load_fixtures`) or production-style (geo organizations
   + a real superuser).
5. **Django admin**: the SPA owns `/admin/*`, so on a single origin the
   Django admin can't be public there. Suggest LAN/Tailscale only. Should
   lumine join the tailnet?
6. **Email**: point SMTP at avocado's Mailpit, or none.
7. **Repo layout**: this `lumine/` directory (nginx site, systemd units,
   provisioning script, env template) + `docs/care-box.md` + `box-*` recipes
   in the `justfile`.

## Phase 0: SSD + boot from SSD

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
  credentials sops-encrypted, ingress `care-box.rithviknishad.dev` →
  `http://localhost:80`, `cloudflared tunnel route dns lumine
  care-box.rithviknishad.dev`. Give the unit the same "retry forever" restart
  policy as avocado's (`modules/cloudflared.nix` explains the outage it fixes).
- Verify through Cloudflare: SPA 200, `/api/v1/plug_config/` 200,
  presigned PUT/GET 200 on both buckets, anonymous GET 403 on `care-uploads`
  and 200 on `care-facility`, presigned URLs carry `X-Amz-Algorithm`.

## Phase 5: Secrets + seeding
- **Fresh** secrets (don't reuse avocado's): Postgres password,
  `DJANGO_SECRET_KEY`, a stable `JWKS_BASE64`, `BUCKET_KEY`/`BUCKET_SECRET`
  in `secrets/care-box.enc.yaml` (add a `.sops.yaml` rule; admin key only).
  A `just` recipe decrypts locally and pipes over SSH into
  `/etc/care/care.env`; plaintext never touches the repo tree or the chat.
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
