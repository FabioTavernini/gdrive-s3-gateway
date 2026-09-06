#!/bin/sh
# Starts `rclone serve s3` against the configured Drive remote.
#
# Required env:
#   RCLONE_CONFIG               path to an rclone.conf containing the remote (default: /config/rclone/rclone.conf)
#   RCLONE_REMOTE                remote:path to serve, e.g. "drive:backups" (default: "drive:")
#   RCLONE_S3_ACCESS_KEY_ID       static access key handed to S3 clients
#   RCLONE_S3_SECRET_ACCESS_KEY   static secret key handed to S3 clients
#
# Optional env:
#   RCLONE_S3_ADDR                listen address (default: ":8080")
#   RCLONE_EXTRA_ARGS              extra flags appended verbatim, e.g. "--log-level DEBUG"
set -eu

: "${RCLONE_CONFIG:?RCLONE_CONFIG must point at an rclone.conf with the drive remote configured}"
: "${RCLONE_REMOTE:=drive:}"
: "${RCLONE_S3_ADDR:=:8080}"
: "${RCLONE_S3_ACCESS_KEY_ID:?RCLONE_S3_ACCESS_KEY_ID is required}"
: "${RCLONE_S3_SECRET_ACCESS_KEY:?RCLONE_S3_SECRET_ACCESS_KEY is required}"

if [ ! -f "$RCLONE_CONFIG" ]; then
  echo "entrypoint: rclone config not found at ${RCLONE_CONFIG}" >&2
  echo "entrypoint: mount a secret/volume with rclone.conf there (see readme.md)" >&2
  exit 1
fi

# shellcheck disable=SC2086
exec rclone serve s3 "${RCLONE_REMOTE}" \
  --config "${RCLONE_CONFIG}" \
  --addr "${RCLONE_S3_ADDR}" \
  --auth-key "${RCLONE_S3_ACCESS_KEY_ID},${RCLONE_S3_SECRET_ACCESS_KEY}" \
  --vfs-cache-mode writes \
  --no-modtime \
  ${RCLONE_EXTRA_ARGS:-} \
  "$@"
