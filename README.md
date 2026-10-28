# Immich Backup Runner

Simple backup script for Immich deployments running with Docker Compose.

It performs a consistency-focused backup flow:

1. Stop all Immich services
2. Rsync the Immich library/upload folder to remote storage
3. Start only the database service
4. Wait until PostgreSQL is ready
5. Create a `pg_dumpall` SQL dump
6. Rsync the SQL dump to remote storage
7. Start all services again

## Scripts

- `immich_backup.sh`
- `immich_restore.sh`

## Requirements

- Linux host with:
  - `docker` (with Compose plugin)
  - `rsync`
  - `ssh`
- Access to the Immich compose directory
- SSH key for remote backup destination

## Usage

```bash
./immich_backup.sh \
  --compose-dir /path/to/immich \
  --library-source /path/to/immich/library \
  --library-dest backupuser@backup.example.com:/srv/backups/immich/library \
  --db-dump-dir /path/to/immich/backups \
  --db-dump-dest backupuser@backup.example.com:/srv/backups/immich/db \
  --identity ~/.ssh/backup_key \
  --port 22 \
  --db-service database \
  --db-user postgres
```

### Password-protected PostgreSQL

Prefer using a password file:

```bash
printf '%s' 'your_postgres_password' > ~/.config/immich_pg_password
chmod 600 ~/.config/immich_pg_password
```

Then run with:

```bash
./immich_backup.sh \
  --compose-dir /path/to/immich \
  --library-source /path/to/immich/library \
  --library-dest backupuser@backup.example.com:/srv/backups/immich/library \
  --db-dump-dir /path/to/immich/backups \
  --db-dump-dest backupuser@backup.example.com:/srv/backups/immich/db \
  --identity ~/.ssh/backup_key \
  --db-password-file ~/.config/immich_pg_password
```

## Cron example

Daily at 02:30 with lock to avoid overlapping runs:

```cron
30 2 * * * /usr/bin/flock -n /tmp/immich_backup.lock /path/to/repo/immich_backup.sh --compose-dir /path/to/immich --library-source /path/to/immich/library --library-dest backupuser@backup.example.com:/srv/backups/immich/library --db-dump-dir /path/to/immich/backups --db-dump-dest backupuser@backup.example.com:/srv/backups/immich/db --identity /home/USER/.ssh/backup_key --port 22 --db-service database --db-user postgres --db-password-file /home/USER/.config/immich_pg_password >> /path/to/repo/backup.log 2>&1
```

## Restore usage

```bash
./immich_restore.sh \
  --target-dir /path/to/immich \
  --library-backup-src backupuser@backup.example.com:/srv/backups/immich/library/ \
  --db-dump-backup-src backupuser@backup.example.com:/srv/backups/immich/db/ \
  --db-dump-dir /path/to/immich/restore_dumps \
  --identity ~/.ssh/backup_key \
  --port 22 \
  --db-service database \
  --db-user postgres
```

Optional:

- `--library-target DIR` (default: `TARGET_DIR/library`)
- `--db-dump-file FILE` to restore a specific fetched dump file
- `--delete-library` to mirror backup exactly (delete extra files in target)
- `--no-auto-flatten` to disable automatic fix for one-level nested library restores

If `TARGET_DIR` contains `docker-compose.yml` or `compose.yaml`, the script restores DB into the compose Postgres service and then starts all services.

Notes for library source path:

- Trailing slash on `--library-backup-src` is optional; restore normalizes it to copy source contents.
- If restore detects a one-level nested Immich root (e.g. `library/immich_library_backup/...`), it auto-flattens by default.

## Notes

- Run manually once before enabling cron, so SSH host key verification is accepted.
- If restored files have different ownership, fix with `chown` on restore target before starting Immich.
