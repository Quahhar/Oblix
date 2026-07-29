#!/usr/bin/env bash
#
# Restore an Oblix backup pair produced by backup.sh.
#
# DESTRUCTIVE: this REPLACES the current database contents (the dump was taken
# with --clean --if-exists, so it drops and recreates every object).
#
# The upload archive is optional. If supplied, the current uploads directory is
# moved aside (not deleted) before the archive is extracted.
#
# Usage:
#   ./restore.sh DB.sql.gz [UPLOADS.tar.gz]
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <backup.sql.gz> [uploads.tar.gz]" >&2
  exit 1
fi
file="$1"
if [ ! -f "$file" ]; then
  echo "no such file: $file" >&2
  exit 1
fi
uploads_file="${2:-}"
if [ -n "$uploads_file" ] && [ ! -f "$uploads_file" ]; then
  echo "no such file: $uploads_file" >&2
  exit 1
fi
gzip -t "$file"
if [ -n "$uploads_file" ]; then
  tar -tzf "$uploads_file" >/dev/null
  if tar -tzf "$uploads_file" | grep -Ev '^uploads(/|$)' | grep -q .; then
    echo "unsafe upload archive: entries must stay under uploads/" >&2
    exit 1
  fi
fi

APP_DIR="${OBLIX_DIR:-/var/oblix}"
cd "$APP_DIR"
set -a
# shellcheck disable=SC1091
. ./.env
set +a

echo "About to restore '$file' into database '$POSTGRES_DB'."
if [ -n "$uploads_file" ]; then
  echo "Attachments will also be restored from '$uploads_file'."
fi
echo "This REPLACES all current data. Ctrl-C within 5s to abort."
sleep 5

gunzip -c "$file" \
  | docker compose -f docker-compose.prod.yml exec -T db \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q

if [ -n "$uploads_file" ]; then
  previous="uploads.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -d uploads ]; then
    mv uploads "$previous"
  fi
  tar -xzf "$uploads_file" -C "$APP_DIR"
  echo "previous attachments retained at: $APP_DIR/$previous"
fi

echo "restore complete."
