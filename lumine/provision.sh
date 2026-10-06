#!/usr/bin/env bash
# Base system for CARE in a box on lumine (lumine/PLAN.md, docs/care-box.md):
# packages, the cloudflared apt repo, the pinned VersityGW binary, the
# `care` and `versitygw` users and their directories, Postgres tuning and the
# `care` role/db, the systemd units in lumine/systemd/, the nginx site and the
# cloudflared config. Secrets are separate: lumine/render-secrets.sh.
#
# Idempotent: every step compares against the current state and only changes
# what differs, so re-running it is safe and is how edits under lumine/ get
# applied. It installs missing packages but never upgrades existing ones
# (that's `just box-upgrade`), and never touches /boot/firmware or the EEPROM.
#
# Runs from /usr/local/lib/care-box, the root-owned copy of lumine/ that
# `just box-sync` keeps current; the box has no repo checkout of its own.
#
#   just box-provision        (from the admin machine)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "provision.sh: run as root" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
# runuser'd commands (postgres) can't read the repo checkout's cwd.
cd /
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DEBIAN_FRONTEND=noninteractive

# Checksums are pinned here rather than fetched next to the download, so the
# repo records exactly which bytes run on the box. VersityGW = the image tag
# in k8s/care/care.yaml.
VERSITYGW_VERSION=1.8.0
VERSITYGW_SHA256=b34051d33f5a9c457f790896acb7bd7d7e15ad8d92efb70616b924f37e401910
# "CloudFlare Software Packaging 2025": Cloudflare rolled its signing key on
# 2025-10-30 and the old one no longer verifies packages on trixie.
CLOUDFLARE_KEY_FPR=CC94B39C77AE7342A68B89628A682D308D4E5E73

PACKAGES=(
  postgresql-17 redis-server nginx cloudflared
  git rsync awscli curl ca-certificates gnupg
  # Build deps of CARE's venv: the same set as the builder stage of
  # upstream's docker/prod.Dockerfile, plus Debian's split-out venv/headers.
  build-essential python3-dev python3-venv libpq-dev libjpeg-dev zlib1g-dev
  libgmp-dev libffi-dev libopenjp2-7-dev
  # Runtime: compilemessages (gettext), python-magic (libmagic), weasyprint
  # PDF rendering (pango/harfbuzz).
  gettext libmagic1t64 libpango-1.0-0 libpangoft2-1.0-0 libharfbuzz0b
  libharfbuzz-subset0
)

log() { printf '==> %s\n' "$*"; }

# Install src to dest unless content, mode and owner already match. Succeeds
# only when something changed, so callers can `if put ...; then restart; fi`.
put() {
  local src=$1 dest=$2 mode=$3 owner=${4:-root:root}
  if [ -f "$dest" ] && cmp -s "$src" "$dest" &&
    [ "$(stat -c '%a %U:%G' "$dest")" = "$mode $owner" ]; then
    return 1
  fi
  install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dest"
  log "installed $dest"
}

# Primary-key fingerprint of a keyring file, or nothing unless it holds
# exactly one key: apt trusts every key in a signed-by file, so a second key
# would be trusted for the repo as well.
key_fpr() {
  local colons
  colons=$(gpg --show-keys --with-colons "$1" 2>/dev/null) || return 0
  [ "$(grep -c '^pub:' <<<"$colons")" -eq 1 ] || return 0
  awk -F: '$1 == "fpr" { print $10; exit }' <<<"$colons"
}

# --- apt: cloudflared repo + packages ---------------------------------------
cf_key=/usr/share/keyrings/cloudflare-main.gpg
if [ "$(key_fpr "$cf_key")" != "$CLOUDFLARE_KEY_FPR" ]; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o "$tmp/cf.key"
  [ "$(key_fpr "$tmp/cf.key")" = "$CLOUDFLARE_KEY_FPR" ] ||
    { echo "cloudflare signing key fingerprint mismatch" >&2; exit 1; }
  # signed-by=*.gpg must be a binary keyring.
  if grep -q 'BEGIN PGP' "$tmp/cf.key"; then
    gpg --dearmor <"$tmp/cf.key" >"$tmp/cf.gpg"
  else
    cp "$tmp/cf.key" "$tmp/cf.gpg"
  fi
  install -m 644 "$tmp/cf.gpg" "$cf_key"
  log "installed $cf_key"
fi
echo "deb [signed-by=$cf_key] https://pkg.cloudflare.com/cloudflared any main" >"$tmp/cloudflared.list"
sources_changed=false
if put "$tmp/cloudflared.list" /etc/apt/sources.list.d/cloudflared.list 644; then
  sources_changed=true
fi

missing=()
for p in "${PACKAGES[@]}"; do
  [ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null)" = "ii " ] || missing+=("$p")
done
if $sources_changed || [ ${#missing[@]} -gt 0 ]; then
  apt-get update -q
fi
if [ ${#missing[@]} -gt 0 ]; then
  log "installing: ${missing[*]}"
  apt-get install -y -q --no-install-recommends "${missing[@]}"
fi

# Debian enables a catch-all welcome site on 0.0.0.0:80. Nothing should
# listen on the LAN by accident (lumine has no firewall); the CARE site is
# installed separately and binds where it means to.
if [ -L /etc/nginx/sites-enabled/default ]; then
  rm /etc/nginx/sites-enabled/default
  systemctl try-reload-or-restart nginx
  log "disabled nginx default site"
fi

# --- pinned release binaries -------------------------------------------------
# sops and just were needed while the box ran its own recipes from a repo
# clone. avocado is the control plane now (secrets arrive decrypted over
# SSH), so they're removed: nothing on the box can decrypt the repo's secrets.
if [ -e /usr/local/bin/sops ]; then
  rm -f /usr/local/bin/sops
  log "removed /usr/local/bin/sops"
fi
if [ "$(dpkg-query -W -f='${db:Status-Abbrev}' just 2>/dev/null)" = "ii " ]; then
  apt-get purge -y -q just
  log "purged just"
fi

# The tarball is what's checksummed upstream, so the installed binary is
# recognised by the version it reports.
if ! /usr/local/bin/versitygw --version 2>/dev/null | grep -qE "^Version *: $VERSITYGW_VERSION\$"; then
  vgw=versitygw_v${VERSITYGW_VERSION}_Linux_arm64
  curl -fsSL -o "$tmp/vgw.tar.gz" \
    "https://github.com/versity/versitygw/releases/download/v$VERSITYGW_VERSION/$vgw.tar.gz"
  echo "$VERSITYGW_SHA256  $tmp/vgw.tar.gz" | sha256sum -c --quiet
  tar -xzf "$tmp/vgw.tar.gz" -C "$tmp" "$vgw/versitygw"
  install -m 755 "$tmp/$vgw/versitygw" /usr/local/bin/versitygw
  log "installed versitygw $VERSITYGW_VERSION"
fi

# --- care user + directories -------------------------------------------------
# Home is /opt/care so pip/pipenv caches sit next to the (rebuildable) code
# and venv, keeping /var/lib/care for data that actually needs backing up.
if ! id care >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /opt/care --shell /usr/sbin/nologin care
  log "created user care"
fi
# Owns the uploaded files (/var/lib/care/s3). A static user, not DynamicUser=,
# so their ownership stays stable across restores and the later SSD move.
if ! id versitygw >/dev/null 2>&1; then
  useradd --system --user-group --no-create-home --home-dir /nonexistent \
    --shell /usr/sbin/nologin versitygw
  log "created user versitygw"
fi
install -d -m 755 -o care -g care /opt/care
install -d -m 755 /var/lib/care
# Holds the rendered env file with decrypted secrets: root only.
install -d -m 700 /etc/care

# --- backup source (avocado pulls) ----------------------------------------------
# avocado's care-box-backup service logs in as care-backup and can only run
# backup/backup-source.sh (a pg_dump or a read-only rsync of the uploads):
# the key is locked to it by a forced command in a root-owned
# authorized_keys, and sudo allows that script and nothing else. A real
# shell (/bin/sh) because sshd runs forced commands through it; the account
# has no password, so the key is the only way in.
if ! id care-backup >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /var/lib/care-backup --shell /bin/sh care-backup
  log "created user care-backup"
fi
install -d -m 755 /var/lib/care-backup /var/lib/care-backup/.ssh
put "$here/backup/authorized_keys" /var/lib/care-backup/.ssh/authorized_keys 644 || true
echo 'care-backup ALL=(root) NOPASSWD: /usr/local/lib/care-box/backup/backup-source.sh *' >"$tmp/sudoers"
visudo -cqf "$tmp/sudoers"
put "$tmp/sudoers" /etc/sudoers.d/care-backup 440 || true

# --- postgres ----------------------------------------------------------------
if put "$here/postgresql/care-box.conf" /etc/postgresql/17/main/conf.d/care-box.conf 644; then
  systemctl restart postgresql@17-main
fi
# Peer auth over the unix socket (Debian's default `local all all peer`):
# the `care` OS user is the `care` role, so no DB password exists anywhere.
# Not a superuser; as the db owner it can still create the trusted pg_trgm
# extension CARE's migrations need.
pg() { runuser -u postgres -- psql -XtAq -c "$1"; }
if [ "$(pg "SELECT 1 FROM pg_roles WHERE rolname = 'care'")" != 1 ]; then
  runuser -u postgres -- createuser care
  log "created postgres role care"
fi
if [ "$(pg "SELECT 1 FROM pg_database WHERE datname = 'care'")" != 1 ]; then
  runuser -u postgres -- createdb --owner care care
  log "created database care"
fi

# --- systemd units -------------------------------------------------------------
# Installed here, enabled by whatever needs them first (care.target by
# deploy-backend.sh, once there is a release to run).
changed_units=()
for f in "$here"/systemd/*; do
  if put "$f" "/etc/systemd/system/${f##*/}" 644; then
    changed_units+=("${f##*/}")
  fi
done
if [ ${#changed_units[@]} -gt 0 ]; then
  systemctl daemon-reload
  # Picks up the change in running units; stopped ones stay stopped.
  systemctl try-restart "${changed_units[@]}"
fi
# Come up at boot. The first start happens in render-secrets.sh, once their
# credentials exist (both units are ConditionPathExists= on them).
systemctl enable --quiet versitygw.service cloudflared-lumine.service

# --- nginx + cloudflared config -------------------------------------------------
# An invalid site must not take nginx down: test it, and put the previous
# version back if the test fails.
site=/etc/nginx/conf.d/care-box.conf
if [ -f "$site" ]; then cp -p "$site" "$tmp/site.bak"; fi
if put "$here/nginx/care-box.conf" "$site" 644; then
  if nginx -t 2>"$tmp/nginx-t"; then
    systemctl reload nginx
  else
    cat "$tmp/nginx-t" >&2
    if [ -f "$tmp/site.bak" ]; then cp -p "$tmp/site.bak" "$site"; else rm -f "$site"; fi
    echo "provision.sh: nginx rejected lumine/nginx/care-box.conf; previous site kept" >&2
    exit 1
  fi
fi
if put "$here/cloudflared/config.yml" /etc/cloudflared/config.yml 644; then
  systemctl try-restart cloudflared-lumine.service
fi

log "provisioned"
