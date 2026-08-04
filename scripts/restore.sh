#!/usr/bin/env bash
#
# Restores a backup directory produced by scripts/backup.sh.
#
#   make restore FILE=backups/20260804-181500
#
# Destructive: it drops and recreates the n8n database, and replaces the
# contents of the n8n_data volume. Asks for confirmation first.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SRC=${1:-}

if [[ -z $SRC ]]; then
	echo "Usage: make restore FILE=backups/<timestamp>" >&2
	echo >&2
	echo "Available backups:" >&2
	ls -1 backups/ 2>/dev/null | sed 's/^/  backups\//' >&2 || echo "  (none)" >&2
	exit 1
fi

SRC=${SRC%/}
[[ -f "$SRC/database.dump" ]] || { echo "$SRC/database.dump not found" >&2; exit 1; }
[[ -f "$SRC/n8n_data.tgz" ]]  || { echo "$SRC/n8n_data.tgz not found" >&2; exit 1; }

n8n_volume=$(docker compose config --format json \
	| python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["n8n_data"]["name"])')

cat <<EOF
About to restore from $SRC

  - the n8n database will be DROPPED and recreated from database.dump
  - the contents of volume $n8n_volume will be REPLACED by n8n_data.tgz
  - the n8n container will be stopped during the operation

Everything currently in this instance will be lost.
EOF

read -r -p "Type 'restore' to continue: " answer
[[ $answer == restore ]] || { echo "aborted"; exit 1; }

echo "Stopping n8n so nothing writes during the restore..."
docker compose stop n8n

echo "Making sure postgres is up..."
docker compose up -d postgres
until docker compose exec -T postgres sh -c 'pg_isready -U "$POSTGRES_USER" -d postgres' >/dev/null 2>&1; do
	printf '.'
	sleep 2
done
echo

echo "Recreating the database..."
# Connect to the maintenance database, since the target one is being replaced.
docker compose exec -T postgres sh -c '
	set -e
	psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);"
	psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";"
'

echo "Loading the dump..."
docker compose exec -T postgres sh -c \
	'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-acl' < "$SRC/database.dump"

echo "Restoring the n8n_data volume (encryption key)..."
docker run --rm \
	-v "$n8n_volume:/dst" \
	-v "$PWD/$SRC:/in:ro" \
	alpine sh -c 'rm -rf /dst/* /dst/..?* /dst/.[!.]* 2>/dev/null; tar xzf /in/n8n_data.tgz -C /dst'

echo "Starting n8n..."
docker compose up -d
docker compose ps

cat <<EOF

Restore complete. Verify before declaring victory:
  - log in and open a workflow
  - open a credential and confirm it decrypts (this proves the encryption key
    from n8n_data.tgz matches the restored database)
  - check the logs: make logs S=n8n

$SRC/env holds the .env that was in place when the backup was taken; it was NOT
restored automatically.
EOF
