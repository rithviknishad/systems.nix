#!/usr/bin/env bash
# Forced command for avocado's care-box backup pull (lumine/backup/authorized_keys,
# modules/care-box.nix). Runs as root through a sudoers rule that allows only
# this script, and answers exactly two requests:
#
#   pg_dump                  the `care` database, custom format, to stdout
#   rsync --server --sender  the VersityGW tree /var/lib/care/s3, read-only,
#                            through rrsync (which vets the rsync options)
#
# Anything else is refused. Root because VersityGW's tree is versitygw-only
# (0750) and pg_dump runs as postgres; nothing here can write.
set -euo pipefail

req=${1:-}
cd /
case "$req" in
pg_dump)
  exec runuser -u postgres -- pg_dump --format=custom care
  ;;
"rsync --server --sender "*)
  SSH_ORIGINAL_COMMAND=$req exec /usr/bin/rrsync -ro /var/lib/care/s3/
  ;;
*)
  echo "backup-source.sh: refused: ${req:-<no command>}" >&2
  exit 1
  ;;
esac
