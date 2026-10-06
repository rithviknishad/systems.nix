#!/usr/bin/env bash
# Write lumine's secrets into root-only (0600) files, one per consumer, so
# each service sees only its own:
#
#   /etc/care/care.env           settings template + app secrets   care.target
#   /etc/care/versitygw.env      gateway root credentials only      versitygw
#   /etc/cloudflared/<id>.json   tunnel credentials                 cloudflared-lumine
#
# The box can't decrypt anything itself: the admin machine (avocado or the
# Mac) decrypts secrets/care-box.enc.env + secrets/lumine-cloudflared.json
# with its own key and streams them in on stdin, as the dotenv followed by a
# _TUNNEL_JSON_B64=<base64 credentials> line. Plaintext only ever exists in
# memory and in those files: never on disk elsewhere, never on stdout or in
# argv. A file is rewritten only if its content changed;
# its consumer is then restarted (care.target only if already running, the
# others whenever they're enabled but not running). The env files are
# verified through systemd's own EnvironmentFile= parser, reporting key
# names only.
#
#   just box-secrets-render        (from the admin machine)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "render-secrets.sh: run as root" >&2; exit 1; }
[ ! -t 0 ] || { echo "render-secrets.sh: expects the secrets on stdin; use just box-secrets-render" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
helper=$here/care/render_env.py
template=$here/care/care.env
# = `tunnel:` in lumine/cloudflared/config.yml.
TUNNEL_ID=1e284975-9221-4b79-8242-0722c96294ed

umask 077
install -d -m 700 /etc/care
install -d -m 755 /etc/cloudflared
staged=()
trap 'rm -f "${staged[@]}"' EXIT
# Stage next to the destination: same filesystem (atomic mv) and the same
# root-only directory, so plaintext never lands in /tmp.
stage() { STAGED=$(mktemp "${1%/*}/.${1##*/}.XXXXXX"); staged+=("$STAGED"); }
# Succeeds only if dest changed.
replace() {
  if cmp -s "$2" "$1" && [ "$(stat -c '%a %U' "$1")" = "600 root" ]; then
    echo "$1 unchanged"
    return 1
  fi
  chmod 600 "$2"
  mv -f "$2" "$1"
  echo "$1 updated"
}

# printf pipes rather than here-strings: bash may back those with a temp file.
input=$(cat)
tunnel_b64=$(printf '%s\n' "$input" | sed -n 's/^_TUNNEL_JSON_B64=//p')
app=$(printf '%s\n' "$input" | grep -v '^_TUNNEL_JSON_B64=' || true)
unset input
# A truncated stream (the sender died mid-way) must not render half a config.
[ -n "$tunnel_b64" ] || { echo "render-secrets.sh: no _TUNNEL_JSON_B64 line on stdin" >&2; exit 1; }
[ -n "$app" ] || { echo "render-secrets.sh: no app secrets on stdin" >&2; exit 1; }

care_env=/etc/care/care.env
stage "$care_env"
printf '%s\n' "$app" | python3 "$helper" render care "$template" >"$STAGED"
care_changed=false
if replace "$care_env" "$STAGED"; then care_changed=true; fi

vgw_env=/etc/care/versitygw.env
stage "$vgw_env"
printf '%s\n' "$app" | python3 "$helper" render versitygw >"$STAGED"
vgw_changed=false
if replace "$vgw_env" "$STAGED"; then vgw_changed=true; fi

creds=/etc/cloudflared/$TUNNEL_ID.json
stage "$creds"
printf '%s' "$tunnel_b64" | base64 -d >"$STAGED"
python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["TunnelID"] != sys.argv[2])' \
  "$STAGED" "$TUNNEL_ID" || { echo "tunnel credentials are not for $TUNNEL_ID" >&2; exit 1; }
creds_changed=false
if replace "$creds" "$STAGED"; then creds_changed=true; fi

# The decrypted secrets go in on stdin, so the check never decrypts again.
check() {
  printf '%s\n' "$app" | systemd-run --quiet --wait --pipe --collect \
    -p EnvironmentFile="$2" python3 "$helper" check "$1" "${@:3}"
}
check care "$care_env" "$template"
check versitygw "$vgw_env"

if $care_changed && systemctl is-active --quiet care.target; then
  systemctl restart care.target
  echo "restarted care.target"
fi
for pair in "versitygw.service $vgw_changed" "cloudflared-lumine.service $creds_changed"; do
  set -- $pair
  if systemctl is-enabled --quiet "$1" && { $2 || ! systemctl is-active --quiet "$1"; }; then
    systemctl restart "$1"
    echo "restarted $1"
  fi
done
