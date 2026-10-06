#!/usr/bin/env bash
# Build and roll out the CARE backend on lumine. The build mirrors upstream's
# docker/prod.Dockerfile (venv, `pipenv install --deploy`, install_plugins.py)
# but produces a release directory instead of an image:
#
#   /opt/care/backend/<sha12>-<cfg8>/   checkout + .venv + staticfiles,
#                                       REVISION and build.env
#   /opt/care/backend/current           symlink the care-* units run from
#
# <cfg8> hashes the plug list and the settings module, so changing either
# makes a new release just like a new commit does.
#
# It tracks the branch head (lumine/PLAN.md decision 4): every run resolves
# the head, and if `current` already is that build, nothing happens. A build
# is marked complete only at its very end, so an interrupted run is redone
# from scratch next time while the old release keeps serving.
#
#   just box-deploy [ref] [repo]    (from the admin machine)
set -euo pipefail

REF=${1:-rithviknishad/bodhi/ENG-737-test-fixtures}
REPO=${2:-rithviknishad/care}
# Same pin as upstream's Dockerfile.
PIPENV_VERSION=2025.1.1

[ "$(id -u)" -eq 0 ] || { echo "deploy-backend.sh: run as root" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
# Commands run as care can't read the invoking user's cwd (python -m dies on it).
cd /
base=/opt/care/backend
log() { printf '==> %s\n' "$*"; }
die() { echo "deploy-backend.sh: $*" >&2; exit 1; }

[ -f /etc/care/care.env ] || die "missing /etc/care/care.env: run just box-secrets-render first"
systemctl cat care.target >/dev/null 2>&1 || die "care units not installed: run just box-provision first"

# avocado's plug list (k8s/care/additional-plugs.json, shipped next to this
# script by `just box-sync`) minus TeleICU, so abdm stays at avocado's pinned
# sha by construction.
plugs=$(python3 - "$here/additional-plugs.json" <<'EOF'
import json, sys
teleicu = {"gateway_device", "camera_device", "vitals_observation_device"}
print(json.dumps([p for p in json.load(open(sys.argv[1])) if p["name"] not in teleicu]))
EOF
)
# It's single-quoted in build.env, which has no escapes inside quotes.
[[ $plugs != *"'"* ]] || die "plug list contains a single quote"
settings=$here/care_box_settings.py

sha=$(git ls-remote "https://github.com/$REPO" "refs/heads/$REF" | cut -f1)
[ -n "$sha" ] || die "no branch $REF in $REPO"
cfg=$( { printf '%s\n' "$plugs"; cat "$settings"; } | sha256sum | cut -c1-8)
id=${sha:0:12}-$cfg
rel=$base/$id

if [ "$(readlink "$base/current" 2>/dev/null)" = "$id" ] && [ -f "$rel/.complete" ]; then
  log "up to date: $REPO@$REF = $id"
  exit 0
fi

# HOME (pip/pipenv caches) becomes care's home, /opt/care.
as_care() { runuser -u care -- "$@"; }

if [ ! -f "$rel/.complete" ]; then
  log "building $REPO@$REF ($sha) into $rel"
  rm -rf "$rel"
  install -d -o care -g care -m 755 "$base"
  as_care git clone -q --depth 1 --branch "$REF" "https://github.com/$REPO" "$rel"
  got=$(as_care git -C "$rel" rev-parse HEAD)
  [ "$got" = "$sha" ] || die "$REF moved during the deploy ($sha -> $got); re-run"

  pipenv=/opt/care/tools/pipenv/bin/pipenv
  if ! "$pipenv" --version 2>/dev/null | grep -qw "$PIPENV_VERSION"; then
    log "installing pipenv $PIPENV_VERSION"
    as_care python3 -m venv /opt/care/tools/pipenv
    as_care /opt/care/tools/pipenv/bin/pip install -q "pipenv==$PIPENV_VERSION"
  fi

  log "venv + Pipfile.lock packages"
  as_care python3 -m venv "$rel/.venv"
  (cd "$rel" && as_care env PIPENV_VENV_IN_PROJECT=1 PIPENV_NOSPIN=1 PIPENV_YES=1 \
    "$pipenv" install --deploy --categories packages)

  log "plugs: $plugs"
  (cd "$rel" && as_care env ADDITIONAL_PLUGS="$plugs" .venv/bin/python install_plugins.py)
  install -o care -g care -m 644 "$settings" "$rel/config/settings/care_box.py"

  # The units load this next to /etc/care/care.env, so the runtime
  # ADDITIONAL_PLUGS is by construction the list that was pip-installed.
  printf "ADDITIONAL_PLUGS='%s'\nAPP_VERSION=%s\n" "$plugs" "$sha" >"$rel/build.env"
  {
    echo "repo=$REPO"
    echo "ref=$REF"
    echo "sha=$sha"
    echo "plugs=$plugs"
    echo "built=$(date -Iseconds)"
    echo "systems.nix=$(cat "$here/../SYSTEMS_NIX_REVISION" 2>/dev/null || echo unknown)"
  } >"$rel/REVISION"
  chown care:care "$rel/build.env" "$rel/REVISION"

  # Once per build rather than on every start (upstream's start.sh does both
  # on each start): STATIC_ROOT and the .mo files live inside the release.
  log "collectstatic + compilemessages"
  CARE_RELEASE=$rel "$here/manage.sh" collectstatic --noinput
  CARE_RELEASE=$rel "$here/manage.sh" compilemessages -v 0
  # The units can't write __pycache__ (read-only /opt), so without this every
  # process start would recompile CARE's sources.
  as_care "$rel/.venv/bin/python" -m compileall -q -j 0 -x '/\.venv/' "$rel"

  touch "$rel/.complete"
fi

log "switching current -> $id"
ln -sfn "$id" "$base/current.new"
mv -T "$base/current.new" "$base/current"
systemctl enable --quiet care.target
# Beat runs migrations before the API and worker start (unit ordering), so
# this blocks until they're done; the first run on an empty DB takes minutes.
log "restarting care.target (beat migrates first)"
systemctl restart care.target

# Keep the running release and the two newest others for rollback. -type d
# so the `current` symlink itself is never a candidate.
mapfile -t stale < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
  sort -rn | cut -d' ' -f2 | grep -vx -- "$id" | tail -n +3)
for d in "${stale[@]}"; do
  rm -rf "${base:?}/$d"
  log "pruned $d"
done

log "deployed:"
cat "$rel/REVISION"
