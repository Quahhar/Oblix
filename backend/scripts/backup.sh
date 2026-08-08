#!/usr/bin/env bash
#
# Daily Postgres + attachment backup for Oblix.
#
# Dumps the database and archives the uploads directory into BACKUP_DIR with a
# shared UTC timestamp, validates both, and prunes backups older than
# RETENTION_DAYS.
# Designed to run from cron (no TTY, explicit PATH, fails loudly).
#
# The dump uses --clean --if-exists so a restore is idempotent (see restore.sh),
# and --no-owner --no-privileges so it restores cleanly regardless of role names.
#
# Env overrides (all optional):
#   OBLIX_DIR                  compose project dir      (default /var/oblix/backend)
#   OBLIX_COMPOSE_PROJECT      Compose project name     (default oblix)
#   OBLIX_BACKUP_DIR           where dumps are written  (default /var/backups/oblix)
#   OBLIX_BACKUP_RETENTION_DAYS days to keep            (default 14)
set -euo pipefail
umask 077

# cron runs with a minimal PATH; make sure docker is findable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

APP_DIR="${OBLIX_DIR:-/var/oblix/backend}"
BACKUP_DIR="${OBLIX_BACKUP_DIR:-/var/backups/oblix}"
RETENTION_DAYS="${OBLIX_BACKUP_RETENTION_DAYS:-14}"
COMPOSE_PROJECT="${OBLIX_COMPOSE_PROJECT:-oblix}"

cd "$APP_DIR"

# Load POSTGRES_USER / POSTGRES_DB from the deployment's .env.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
db_out="$BACKUP_DIR/oblix-${ts}.sql.gz"
uploads_out="$BACKUP_DIR/oblix-uploads-${ts}.tar.gz"
db_tmp="${db_out}.partial"
uploads_tmp="${uploads_out}.partial"
trap 'rm -f "$db_tmp" "$uploads_tmp"' EXIT

# -T: no pseudo-TTY (required under cron).
docker compose --project-name "$COMPOSE_PROJECT" -f docker-compose.prod.yml exec -T db \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists --no-owner --no-privileges \
  | gzip > "$db_tmp"

# Guard against a silent failure (auth error, empty pipe) leaving a tiny file.
db_size="$(stat -c%s "$db_tmp")"
if [ "$db_size" -lt 200 ]; then
  echo "$(date -u +%FT%TZ) backup FAILED: dump too small (${db_size} bytes)" >&2
  exit 1
fi
gzip -t "$db_tmp"

tar -C "$APP_DIR" -czf "$uploads_tmp" uploads
tar -tzf "$uploads_tmp" >/dev/null
uploads_size="$(stat -c%s "$uploads_tmp")"

mv "$db_tmp" "$db_out"
mv "$uploads_tmp" "$uploads_out"
find "$BACKUP_DIR" -name 'oblix-*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
find "$BACKUP_DIR" -name 'oblix-uploads-*.tar.gz' -mtime "+${RETENTION_DAYS}" -delete
trap - EXIT

echo "$(date -u +%FT%TZ) backup OK: ${db_out} (${db_size} bytes), ${uploads_out} (${uploads_size} bytes); kept ${RETENTION_DAYS}d"
