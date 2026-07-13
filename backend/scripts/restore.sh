#!/usr/bin/env bash
#
# Restore an Oblix backup produced by backup.sh.
#
# DESTRUCTIVE: this REPLACES the current database contents (the dump was taken
# with --clean --if-exists, so it drops and recreates every object).
#
# Usage:
#   ./restore.sh /var/backups/oblix/oblix-YYYYMMDDTHHMMSSZ.sql.gz
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ $# -ne 1 ]; then
  echo "usage: $0 <backup.sql.gz>" >&2
  exit 1
fi
file="$1"
if [ ! -f "$file" ]; then
  echo "no such file: $file" >&2
  exit 1
fi

APP_DIR="${OBLIX_DIR:-/var/oblix}"
cd "$APP_DIR"
set -a
# shellcheck disable=SC1091
. ./.env
set +a

echo "About to restore '$file' into database '$POSTGRES_DB'."
echo "This REPLACES all current data. Ctrl-C within 5s to abort."
sleep 5

gunzip -c "$file" \
  | docker compose -f docker-compose.prod.yml exec -T db \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q

echo "restore complete."
