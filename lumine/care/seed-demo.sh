#!/usr/bin/env bash
# Demo data for care-box (lumine/PLAN.md decision 5): CARE's load_fixtures
# (org tree, facilities, demo users with the well-known password Ohcn@123,
# sample patients), then admin's password set to BOX_ADMIN_PASSWORD, which
# the admin machine decrypts from the sops secrets and sends as the first
# line of stdin. Like avocado's `just care-seed-demo`, except that Faker (a
# dev-only dependency) goes into a throwaway directory instead of the release
# venv, and the weak admin/admin is rotated in the same step.
#
# Idempotent: the fixtures load only into a DB without the demo users,
# because a second load would duplicate the data and load_fixtures always
# resets admin to admin/admin. The password step runs every time and is a
# no-op once set.
#
#   just box-seed-demo        (from the admin machine)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "seed-demo.sh: run as root" >&2; exit 1; }
[ ! -t 0 ] || { echo "seed-demo.sh: expects BOX_ADMIN_PASSWORD on stdin; use just box-seed-demo" >&2; exit 1; }
IFS= read -r admin_pw || true
here=$(cd "$(dirname "$0")" && pwd)
cd /
manage=$here/manage.sh
rel=$(readlink -f /opt/care/backend/current)
log() { printf '==> %s\n' "$*"; }

# </dev/null keeps manage.sh on plain pipes (no pty) so output parses cleanly.
seeded=$("$manage" shell -v 0 -c \
  'from django.contrib.auth import get_user_model; print(get_user_model().objects.filter(username="care-admin").exists())' \
  </dev/null | tail -n 1)

if [ "$seeded" = True ]; then
  log "demo fixtures already loaded (user care-admin exists); not loading again"
else
  dir=$(runuser -u care -- mktemp -d /tmp/care-faker.XXXXXX)
  trap 'rm -rf "$dir"' EXIT
  # Faker at the version upstream's Pipfile.lock pins for dev, and its
  # dependencies constrained to the lock as well, so the throwaway copies
  # match what the venv already has.
  python3 - "$rel/Pipfile.lock" "$dir/constraints.txt" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
pins = {n: p["version"] for s in ("default", "develop") for n, p in lock[s].items() if "version" in p}
open(sys.argv[2], "w").write("".join(f"{n}{v}\n" for n, v in sorted(pins.items())))
EOF
  faker=$(grep -i '^faker==' "$dir/constraints.txt")
  log "installing $faker into $dir (outside the release venv)"
  runuser -u care -- "$rel/.venv/bin/pip" install -q --target "$dir/site" -c "$dir/constraints.txt" "$faker"
  # The fixture context refuses to run unless settings.DEBUG; this turns it
  # on for this one process only.
  log "load_fixtures (DEBUG on for this process only)"
  "$manage" --setenv=DJANGO_DEBUG=true --setenv=PYTHONPATH="$dir/site" load_fixtures </dev/null
fi

# The password reaches Python only through this pipe, never argv or the
# environment, and the code never echoes it. printf is a builtin, so no argv.
log "admin password <- BOX_ADMIN_PASSWORD"
printf '%s\n' "$admin_pw" |
  "$manage" shell -v 0 -c '
import sys
from django.contrib.auth import get_user_model
pw = sys.stdin.readline().rstrip("\n")
if len(pw) < 12:
    sys.exit("BOX_ADMIN_PASSWORD is missing or shorter than 12 characters")
user = get_user_model().objects.get(username="admin")
if user.check_password(pw):
    print("admin password already set from BOX_ADMIN_PASSWORD")
else:
    user.set_password(pw)
    user.save(update_fields=["password"])
    print("admin password set from BOX_ADMIN_PASSWORD")
'
