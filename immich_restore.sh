#!/usr/bin/env bash
#
# immich_restore.sh
#
# Restore flow:
#  1) rsync library backup from remote to local target
#  2) rsync DB dump backup (file or directory) from remote to local staging dir
#  3) choose SQL dump file (explicit or auto-detect)
#  4) if compose exists in target dir:
#     - start DB service
#     - wait for readiness
#     - restore SQL
#     - start all services
#
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 \
  --target-dir DIR \
  --library-backup-src SRC \
  --db-dump-backup-src SRC \
  --db-dump-dir DIR \
  --identity KEY \
  [--library-target DIR] \
  [--db-dump-file FILE] \
  [--port PORT] \
  [--db-service NAME] \
  [--db-user USER] \
  [--db-password PASSWORD] \
  [--db-password-file FILE] \
  [--db-ready-timeout SEC] \
  [--delete-library] \
  [--no-auto-flatten]

Required:
  --target-dir DIR         Restore destination root. If compose file exists here,
                           DB restore is applied and all services are started.
  --library-backup-src SRC Remote rsync source for library backup (user@host:/path)
  --db-dump-backup-src SRC Remote rsync source for DB dump backup (file or dir)
  --db-dump-dir DIR        Local staging directory for fetched SQL dumps
  --identity KEY           SSH private key path

Optional:
  --library-target DIR     Local library restore target
                           (default: TARGET_DIR/library)
  --db-dump-file FILE      Specific SQL file to restore from fetched dumps
                           (absolute path or path/basename inside fetched content)
  --port PORT              SSH port (default: 22)
  --db-service NAME        Compose Postgres service name (default: database)
  --db-user USER           Postgres user for restore (default: postgres)
  --db-password PASSWORD   Postgres password (less secure: visible in args/history)
  --db-password-file FILE  File containing Postgres password (recommended)
  --db-ready-timeout SEC   Seconds to wait for DB readiness (default: 60)
  --delete-library         Mirror backup exactly (delete extra files in target)
  --no-auto-flatten        Disable automatic one-level nested library fix
EOF
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

TARGET_DIR=""
LIBRARY_BACKUP_SRC=""
LIBRARY_TARGET=""
DB_DUMP_BACKUP_SRC=""
DB_DUMP_DIR=""
DB_DUMP_FILE=""
IDENTITY=""
PORT="22"
DB_SERVICE="database"
DB_USER="postgres"
DB_PASSWORD=""
DB_PASSWORD_FILE=""
DB_READY_TIMEOUT="60"
DELETE_LIBRARY=0
AUTO_FLATTEN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)         TARGET_DIR="$2"; shift 2 ;;
    --library-backup-src) LIBRARY_BACKUP_SRC="$2"; shift 2 ;;
    --library-target)     LIBRARY_TARGET="$2"; shift 2 ;;
    --db-dump-backup-src) DB_DUMP_BACKUP_SRC="$2"; shift 2 ;;
    --db-dump-dir)        DB_DUMP_DIR="$2"; shift 2 ;;
    --db-dump-file)       DB_DUMP_FILE="$2"; shift 2 ;;
    --identity)           IDENTITY="$2"; shift 2 ;;
    --port)               PORT="$2"; shift 2 ;;
    --db-service)         DB_SERVICE="$2"; shift 2 ;;
    --db-user)            DB_USER="$2"; shift 2 ;;
    --db-password)        DB_PASSWORD="$2"; shift 2 ;;
    --db-password-file)   DB_PASSWORD_FILE="$2"; shift 2 ;;
    --db-ready-timeout)   DB_READY_TIMEOUT="$2"; shift 2 ;;
    --delete-library)     DELETE_LIBRARY=1; shift 1 ;;
    --no-auto-flatten)    AUTO_FLATTEN=0; shift 1 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$TARGET_DIR" && -n "$LIBRARY_BACKUP_SRC" && -n "$DB_DUMP_BACKUP_SRC" && -n "$DB_DUMP_DIR" && -n "$IDENTITY" ]] \
  || { usage; exit 1; }

if [[ -z "$LIBRARY_TARGET" ]]; then
  LIBRARY_TARGET="${TARGET_DIR%/}/library"
fi

command -v rsync >/dev/null || fail "rsync not found in PATH"
[[ -f "$IDENTITY" ]] || fail "identity file does not exist: $IDENTITY"

if [[ -n "$DB_PASSWORD" && -n "$DB_PASSWORD_FILE" ]]; then
  fail "use only one of --db-password or --db-password-file"
fi

if [[ -n "$DB_PASSWORD_FILE" ]]; then
  [[ -f "$DB_PASSWORD_FILE" ]] || fail "db password file does not exist: $DB_PASSWORD_FILE"
  DB_PASSWORD="$(<"$DB_PASSWORD_FILE")"
fi

mkdir -p "$TARGET_DIR" "$LIBRARY_TARGET" "$DB_DUMP_DIR"

if [[ -f "$TARGET_DIR/docker-compose.yml" || -f "$TARGET_DIR/compose.yaml" ]]; then
  HAS_COMPOSE=1
else
  HAS_COMPOSE=0
fi

if [[ "$HAS_COMPOSE" -eq 1 ]]; then
  command -v docker >/dev/null || fail "docker not found in PATH"
fi

# --- Step 1: restore library -------------------------------------------------
# normalize for rsync: always copy source directory contents
LIBRARY_BACKUP_SRC_NORM="${LIBRARY_BACKUP_SRC%/}/"

log "Restoring library: $LIBRARY_BACKUP_SRC_NORM -> ${LIBRARY_TARGET%/}/"
if [[ "$DELETE_LIBRARY" -eq 1 ]]; then
  rsync -av --delete --progress \
    -e "ssh -p ${PORT} -i ${IDENTITY} -o IdentitiesOnly=yes" \
    "$LIBRARY_BACKUP_SRC_NORM" "${LIBRARY_TARGET%/}/"
else
  rsync -av --progress \
    -e "ssh -p ${PORT} -i ${IDENTITY} -o IdentitiesOnly=yes" \
    "$LIBRARY_BACKUP_SRC_NORM" "${LIBRARY_TARGET%/}/"
fi

# validate/fix expected Immich layout at library root
EXPECTED_LIBRARY_DIRS=("encoded-video" "library" "thumbs" "upload")
missing=()
for d in "${EXPECTED_LIBRARY_DIRS[@]}"; do
  [[ -d "${LIBRARY_TARGET%/}/$d" ]] || missing+=("$d")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  log "Library layout check: missing top-level dirs in ${LIBRARY_TARGET%/}: ${missing[*]}"

  if [[ "$AUTO_FLATTEN" -eq 1 ]]; then
    log "Attempting one-level auto-flatten of nested library backup..."

    candidates=()
    shopt -s nullglob
    for child in "${LIBRARY_TARGET%/}"/*; do
      [[ -d "$child" ]] || continue
      candidate_ok=1
      for d in "${EXPECTED_LIBRARY_DIRS[@]}"; do
        [[ -d "$child/$d" ]] || { candidate_ok=0; break; }
      done
      [[ "$candidate_ok" -eq 1 ]] && candidates+=("$child")
    done
    shopt -u nullglob

    if [[ ${#candidates[@]} -eq 1 ]]; then
      log "Found nested Immich root: ${candidates[0]}"
      rsync -a "${candidates[0]%/}/" "${LIBRARY_TARGET%/}/"
      rmdir "${candidates[0]}" 2>/dev/null || true
    elif [[ ${#candidates[@]} -gt 1 ]]; then
      fail "multiple nested Immich root candidates found under ${LIBRARY_TARGET%/}; use --library-target or --no-auto-flatten"
    fi
  fi

  missing_after=()
  for d in "${EXPECTED_LIBRARY_DIRS[@]}"; do
    [[ -d "${LIBRARY_TARGET%/}/$d" ]] || missing_after+=("$d")
  done
  [[ ${#missing_after[@]} -eq 0 ]] || fail "library layout invalid in ${LIBRARY_TARGET%/}. Expected dirs: ${EXPECTED_LIBRARY_DIRS[*]}"
fi

# --- Step 2: fetch DB dump backup -------------------------------------------
STAMP="$(date '+%Y%m%d_%H%M%S')"
FETCH_DIR="${DB_DUMP_DIR%/}/restore_fetch_${STAMP}"
mkdir -p "$FETCH_DIR"

log "Fetching DB dump backup: $DB_DUMP_BACKUP_SRC -> $FETCH_DIR/"
rsync -av --progress \
  -e "ssh -p ${PORT} -i ${IDENTITY} -o IdentitiesOnly=yes" \
  "$DB_DUMP_BACKUP_SRC" "$FETCH_DIR/"

# --- Step 3: choose SQL dump -------------------------------------------------
SELECTED_DUMP=""

if [[ -n "$DB_DUMP_FILE" ]]; then
  if [[ -f "$DB_DUMP_FILE" ]]; then
    SELECTED_DUMP="$DB_DUMP_FILE"
  elif [[ -f "$FETCH_DIR/$DB_DUMP_FILE" ]]; then
    SELECTED_DUMP="$FETCH_DIR/$DB_DUMP_FILE"
  else
    SELECTED_DUMP="$(find "$FETCH_DIR" -type f -name "$(basename "$DB_DUMP_FILE")" | head -n1 || true)"
  fi
  [[ -n "$SELECTED_DUMP" && -f "$SELECTED_DUMP" ]] || fail "requested dump file not found: $DB_DUMP_FILE"
else
  SELECTED_DUMP="$(find "$FETCH_DIR" -type f -name 'immich_pg_dumpall_*.sql' -printf '%f\t%p\n' | sort -k1,1 | tail -n1 | cut -f2- || true)"
  if [[ -z "$SELECTED_DUMP" ]]; then
    SELECTED_DUMP="$(find "$FETCH_DIR" -type f -name '*.sql' -printf '%T@\t%p\n' | sort -n | tail -n1 | cut -f2- || true)"
  fi
  [[ -n "$SELECTED_DUMP" && -f "$SELECTED_DUMP" ]] || fail "no SQL dump file found in fetched DB backup"
fi

log "Selected SQL dump: $SELECTED_DUMP"

# --- Step 4: restore DB and start services (if compose exists) --------------
if [[ "$HAS_COMPOSE" -eq 1 ]]; then
  log "Compose file detected in $TARGET_DIR. Starting DB service: $DB_SERVICE"
  (cd "$TARGET_DIR" && docker compose up -d "$DB_SERVICE")

  log "Waiting for PostgreSQL readiness (timeout: ${DB_READY_TIMEOUT}s)..."
  ready=0
  for ((i=1; i<=DB_READY_TIMEOUT; i++)); do
    if (cd "$TARGET_DIR" && docker compose exec -T "$DB_SERVICE" pg_isready -U "$DB_USER" >/dev/null 2>&1); then
      ready=1
      break
    fi
    sleep 1
  done
  [[ "$ready" -eq 1 ]] || fail "PostgreSQL did not become ready in ${DB_READY_TIMEOUT}s"

  log "Restoring PostgreSQL from dump..."
  if [[ -n "$DB_PASSWORD" ]]; then
    cat "$SELECTED_DUMP" | (
      cd "$TARGET_DIR"
      PGPASSWORD="$DB_PASSWORD" docker compose exec -T -e PGPASSWORD "$DB_SERVICE" psql -U "$DB_USER" -d postgres
    )
  else
    cat "$SELECTED_DUMP" | (cd "$TARGET_DIR" && docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres)
  fi

  log "Starting all compose services..."
  (cd "$TARGET_DIR" && docker compose up -d)
  log "Restore completed successfully."
else
  log "No compose file in $TARGET_DIR. Skipped DB container restore/start."
  log "Library restored and DB dump fetched."
fi
