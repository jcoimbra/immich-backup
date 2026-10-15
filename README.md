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

## Script

- `immich_backup.sh`

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

## Notes

- Run manually once before enabling cron, so SSH host key verification is accepted.
- If restored files have different ownership, fix with `chown` on restore target before starting Immich.
