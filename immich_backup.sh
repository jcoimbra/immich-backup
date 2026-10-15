#!/usr/bin/env bash
#
# immich_backup.sh
#
# Consistent Immich backup flow:
#  1) stop all services
#  2) rsync library/upload directory
#  3) start only postgres service
#  4) wait for postgres readiness
#  5) pg_dumpall to local dump file
#  6) rsync dump file
#  7) start all services
#
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 \
  --compose-dir DIR \
  --library-source SRC \
  --library-dest DEST \
  --db-dump-dir DIR \
  --db-dump-dest DEST \
  --identity KEY \
  [--port PORT] \
  [--db-service NAME] \
  [--db-user USER] \
  [--db-password PASSWORD] \
  [--db-password-file FILE] \
  [--db-ready-timeout SEC]

Required:
  --compose-dir DIR       Directory containing docker-compose.yml/compose.yaml
  --library-source SRC    Immich upload/library source dir (e.g. /data/immich/library)
  --library-dest DEST     Rsync destination for library (user@host:/path)
  --db-dump-dir DIR       Local directory to store SQL dumps (e.g. /data/immich/backups)
  --db-dump-dest DEST     Rsync destination for DB dump file(s)
  --identity KEY          SSH private key path

Optional:
  --port PORT             SSH port (default: 23)
  --db-service NAME       Compose Postgres service name (default: database)
  --db-user USER          Postgres user for pg_dumpall (default: postgres)
  --db-password PASSWORD  Postgres password (less secure: visible in process args/history)
  --db-password-file FILE File containing Postgres password (recommended)
  --db-ready-timeout SEC  Seconds to wait for DB readiness (default: 60)
EOF
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

COMPOSE_DIR=""
LIBRARY_SOURCE=""
LIBRARY_DEST=""
DB_DUMP_DIR=""
DB_DUMP_DEST=""
IDENTITY=""
PORT="23"
DB_SERVICE="database"
DB_USER="postgres"
DB_PASSWORD=""
DB_PASSWORD_FILE=""
DB_READY_TIMEOUT="60"

STOPPED_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-dir)      COMPOSE_DIR="$2"; shift 2 ;;
    --library-source)   LIBRARY_SOURCE="$2"; shift 2 ;;
    --library-dest)     LIBRARY_DEST="$2"; shift 2 ;;
    --db-dump-dir)      DB_DUMP_DIR="$2"; shift 2 ;;
    --db-dump-dest)     DB_DUMP_DEST="$2"; shift 2 ;;
    --identity)         IDENTITY="$2"; shift 2 ;;
    --port)             PORT="$2"; shift 2 ;;
    --db-service)       DB_SERVICE="$2"; shift 2 ;;
    --db-user)          DB_USER="$2"; shift 2 ;;
    --db-password)      DB_PASSWORD="$2"; shift 2 ;;
    --db-password-file) DB_PASSWORD_FILE="$2"; shift 2 ;;
    --db-ready-timeout) DB_READY_TIMEOUT="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$COMPOSE_DIR" && -n "$LIBRARY_SOURCE" && -n "$LIBRARY_DEST" && -n "$DB_DUMP_DIR" && -n "$DB_DUMP_DEST" && -n "$IDENTITY" ]] \
  || { usage; exit 1; }

# --- Sanity checks -----------------------------------------------------------
command -v docker >/dev/null || fail "docker not found in PATH"
command -v rsync  >/dev/null || fail "rsync not found in PATH"

[[ -f "$COMPOSE_DIR/docker-compose.yml" || -f "$COMPOSE_DIR/compose.yaml" ]] \
  || fail "no docker compose file found in $COMPOSE_DIR"

[[ -d "$LIBRARY_SOURCE" ]] || fail "library source dir does not exist: $LIBRARY_SOURCE"
[[ -f "$IDENTITY" ]]       || fail "identity file does not exist: $IDENTITY"

if [[ -n "$DB_PASSWORD" && -n "$DB_PASSWORD_FILE" ]]; then
  fail "use only one of --db-password or --db-password-file"
fi

if [[ -n "$DB_PASSWORD_FILE" ]]; then
  [[ -f "$DB_PASSWORD_FILE" ]] || fail "db password file does not exist: $DB_PASSWORD_FILE"
  DB_PASSWORD="$(<"$DB_PASSWORD_FILE")"
fi

mkdir -p "$DB_DUMP_DIR"

# --- Cleanup: always restore full service state ------------------------------
cleanup() {
  local rc=$?
  if [[ "$STOPPED_ALL" -eq 1 ]]; then
    log "Ensuring all Immich services are started..."
    if (cd "$COMPOSE_DIR" && docker compose start); then
      log "All Immich services started."
    else
      log "ERROR: failed to start all Immich services. Manual intervention required." >&2
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# --- Step 1: stop everything -------------------------------------------------
log "Stopping all Immich services..."
(cd "$COMPOSE_DIR" && docker compose stop)
STOPPED_ALL=1

# --- Step 2: backup library --------------------------------------------------
log "Backing up library: ${LIBRARY_SOURCE%/}/ -> $LIBRARY_DEST"
rsync -av --delete --progress \
  -e "ssh -p ${PORT} -i ${IDENTITY} -o IdentitiesOnly=yes" \
  "${LIBRARY_SOURCE%/}/" "$LIBRARY_DEST"

# --- Step 3: start only postgres service ------------------------------------
log "Starting database service only: $DB_SERVICE"
(cd "$COMPOSE_DIR" && docker compose start "$DB_SERVICE")

# --- Step 4: wait for postgres readiness ------------------------------------
log "Waiting for PostgreSQL readiness (timeout: ${DB_READY_TIMEOUT}s)..."
ready=0
for ((i=1; i<=DB_READY_TIMEOUT; i++)); do
  if (cd "$COMPOSE_DIR" && docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" >/dev/null 2>&1); then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]] || fail "PostgreSQL did not become ready in ${DB_READY_TIMEOUT}s"

# --- Step 5: pg_dumpall ------------------------------------------------------
STAMP="$(date '+%Y%m%d_%H%M%S')"
DB_DUMP_FILE="${DB_DUMP_DIR%/}/immich_pg_dumpall_${STAMP}.sql"

log "Creating PostgreSQL dump: $DB_DUMP_FILE"
if [[ -n "$DB_PASSWORD" ]]; then
  (
    cd "$COMPOSE_DIR"
    PGPASSWORD="$DB_PASSWORD" docker compose exec -T -e PGPASSWORD "$DB_SERVICE" pg_dumpall -U "$DB_USER"
  ) > "$DB_DUMP_FILE"
else
  (cd "$COMPOSE_DIR" && docker compose exec -T "$DB_SERVICE" pg_dumpall -U "$DB_USER") > "$DB_DUMP_FILE"
fi

# --- Step 6: rsync DB dump ---------------------------------------------------
log "Backing up DB dump: $DB_DUMP_FILE -> $DB_DUMP_DEST"
rsync -av --progress \
  -e "ssh -p ${PORT} -i ${IDENTITY} -o IdentitiesOnly=yes" \
  "$DB_DUMP_FILE" "$DB_DUMP_DEST"

log "Backup workflow completed successfully."
