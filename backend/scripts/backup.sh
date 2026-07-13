#!/usr/bin/env bash
#
# Daily Postgres backup for Oblix.
#
# Dumps the database from the running `db` container as plain SQL, gzips it into
# BACKUP_DIR with a UTC timestamp, and prunes dumps older than RETENTION_DAYS.
# Designed to run from cron (no TTY, explicit PATH, fails loudly).
#
# The dump uses --clean --if-exists so a restore is idempotent (see restore.sh),
# and --no-owner --no-privileges so it restores cleanly regardless of role names.
#
# Env overrides (all optional):
#   OBLIX_DIR                  compose project dir      (default /var/oblix)
#   OBLIX_BACKUP_DIR           where dumps are written  (default /var/backups/oblix)
#   OBLIX_BACKUP_RETENTION_DAYS days to keep            (default 14)
set -euo pipefail

# cron runs with a minimal PATH; make sure docker is findable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

APP_DIR="${OBLIX_DIR:-/var/oblix}"
BACKUP_DIR="${OBLIX_BACKUP_DIR:-/var/backups/oblix}"
RETENTION_DAYS="${OBLIX_BACKUP_RETENTION_DAYS:-14}"

cd "$APP_DIR"

# Load POSTGRES_USER / POSTGRES_DB from the deployment's .env.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

mkdir -p "$BACKUP_DIR"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/oblix-${ts}.sql.gz"
tmp="${out}.partial"

# -T: no pseudo-TTY (required under cron).
docker compose -f docker-compose.prod.yml exec -T db \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists --no-owner --no-privileges \
  | gzip > "$tmp"

# Guard against a silent failure (auth error, empty pipe) leaving a tiny file.
size="$(stat -c%s "$tmp")"
if [ "$size" -lt 200 ]; then
  echo "$(date -u +%FT%TZ) backup FAILED: dump too small (${size} bytes)" >&2
  rm -f "$tmp"
  exit 1
fi

mv "$tmp" "$out"
find "$BACKUP_DIR" -name 'oblix-*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "$(date -u +%FT%TZ) backup OK: ${out} (${size} bytes); kept ${RETENTION_DAYS}d"
