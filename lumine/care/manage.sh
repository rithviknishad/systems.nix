#!/usr/bin/env bash
# Run `python manage.py ...` as the care user with exactly the environment
# the care-* units get (same EnvironmentFile= parsing, via systemd-run).
# Defaults to the running release; deploy-backend.sh sets CARE_RELEASE to
# run against a build that isn't live yet. Leading --setenv=K=V options add
# one-off variables for this process only (never secrets: a transient unit's
# environment is visible to every local user via `systemctl show`).
#
#   just box-manage <command> [args...]   (= sudo lumine/care/manage.sh ...)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "manage.sh: run as root" >&2; exit 1; }
extra=()
while [[ ${1:-} == --setenv=* ]]; do
  extra+=(-E "${1#--setenv=}")
  shift
done
rel=$(readlink -f "${CARE_RELEASE:-/opt/care/backend/current}")
[ -x "$rel/.venv/bin/python" ] || { echo "no backend release at $rel: run just box-deploy" >&2; exit 1; }

# A pty for interactive commands (createsuperuser, shell), plain pipes when
# scripted so output and exit codes pass through cleanly.
if [ -t 0 ] && [ -t 1 ]; then io=--pty; else io=--pipe; fi

exec systemd-run --quiet --wait --collect "$io" \
  --uid=care --gid=care \
  -p WorkingDirectory="$rel" \
  -p EnvironmentFile=/etc/care/care.env \
  -p EnvironmentFile="$rel/build.env" \
  -p CacheDirectory=care \
  -E PYTHONUNBUFFERED=1 -E XDG_CACHE_HOME=/var/cache/care "${extra[@]}" \
  "$rel/.venv/bin/python" manage.py "$@"
