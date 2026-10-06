#!/usr/bin/env bash
# Create CARE's buckets on lumine's VersityGW and set their policies: the
# versitygw-buckets Job from k8s/care/care.yaml, minus TeleICU's
# teleicu-gateway bucket. Idempotent (head-bucket || create-bucket; the policy
# put is an overwrite).
#   care-uploads    patient files: private, reachable only via presigned URLs
#   care-facility   facility covers + profile pictures: anonymous s3:GetObject,
#                   because CARE hands these out as plain unsigned URLs.
#                   Listing stays denied.
#
#   just box-buckets        (= sudo lumine/care/buckets.sh)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "buckets.sh: run as root" >&2; exit 1; }
[ -f /etc/care/versitygw.env ] || { echo "missing /etc/care/versitygw.env: run just box-secrets-render" >&2; exit 1; }

# The gateway's root credentials, straight from its env file via systemd, so
# they never pass through this script's arguments or environment.
exec systemd-run --quiet --wait --pipe --collect \
  -p EnvironmentFile=/etc/care/versitygw.env \
  -E AWS_DEFAULT_REGION=ap-south-1 \
  -E AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
  -E AWS_CONFIG_FILE=/dev/null -E AWS_SHARED_CREDENTIALS_FILE=/dev/null \
  sh -euc '
    export AWS_ACCESS_KEY_ID="$ROOT_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$ROOT_SECRET_ACCESS_KEY"
    ep=http://127.0.0.1:7070
    tries=0
    until aws --endpoint-url $ep s3api list-buckets >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ $tries -lt 30 ] || { echo "versitygw not answering on $ep" >&2; exit 1; }
      echo "waiting for versitygw..."
      sleep 2
    done
    for b in care-uploads care-facility; do
      if aws --endpoint-url $ep s3api head-bucket --bucket $b >/dev/null 2>&1; then
        echo "bucket $b exists"
      else
        aws --endpoint-url $ep s3api create-bucket --bucket $b >/dev/null
        echo "bucket $b created"
      fi
    done
    aws --endpoint-url $ep s3api put-bucket-policy --bucket care-facility --policy "{
      \"Version\": \"2012-10-17\", \"Statement\": [{\"Effect\": \"Allow\",
      \"Principal\": \"*\", \"Action\": [\"s3:GetObject\"],
      \"Resource\": [\"arn:aws:s3:::care-facility/*\"]}]}"
    echo "care-facility: anonymous GetObject policy set"
  '
