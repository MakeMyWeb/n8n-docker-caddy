#!/usr/bin/env bash
#
# Backs up everything needed to rebuild this instance:
#
#   database.dump   pg_dump -Fc of the n8n database
#   n8n_data.tgz    the n8n_data volume
#   env             a copy of .env
#
# With --archive, the three files are written as a tar archive on stdout instead of
# backups/<timestamp>/ (messages go to stderr), e.g. streamed through SSH by the
# Symbyoz console to the secondary backups. The temporary copy is removed on exit.
#
# The n8n_data volume is NOT optional. It holds n8n's encryption key
# (/home/node/.n8n/config); restoring a database dump without it gives you back
# workflows whose credentials can never be decrypted again.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ARCHIVE=false
if [ "${1:-}" = "--archive" ]; then
	ARCHIVE=true
	mkdir -p backups
	DEST=$(mktemp -d backups/.archive.XXXXXX)
	trap 'rm -rf "$DEST"' EXIT
	# Keep stdout for the archive, every message goes to stderr
	exec 3>&1 1>&2
else
	STAMP=$(date +%Y%m%d-%H%M%S)
	DEST="backups/$STAMP"
fi

n8n_volume=$(docker compose config --format json \
	| python3 -c 'import json,sys; print(json.load(sys.stdin)["volumes"]["n8n_data"]["name"])')

mkdir -p "$DEST"
chmod 700 "$DEST"

echo "Backing up into $DEST"

echo "  database..."
if ! docker compose exec -T postgres sh -c \
		'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$DEST/database.dump"; then
	echo "pg_dump failed — is the stack running? (make up)" >&2
	rm -rf "$DEST"
	exit 1
fi

echo "  n8n_data volume (encryption key)..."
# The container runs as root, so it owns whatever it writes into the bind mount.
# It sets the mode and hands ownership back, otherwise a non-root caller could
# not chmod the tarball afterwards.
docker run --rm \
	-v "$n8n_volume:/src:ro" \
	-v "$PWD/$DEST:/out" \
	alpine sh -c "tar czf /out/n8n_data.tgz -C /src . \
		&& chmod 600 /out/n8n_data.tgz \
		&& chown $(id -u):$(id -g) /out/n8n_data.tgz"

echo "  .env..."
cp .env "$DEST/env"

chmod 600 "$DEST/database.dump" "$DEST/env"

if $ARCHIVE; then
	tar cf - -C "$DEST" . >&3
	exit 0
fi

echo
du -sh "$DEST"
ls -l "$DEST"
echo
echo "Restore with: make restore FILE=$DEST"
echo "Copy this directory off the host — a backup living only on the machine it"
echo "protects is not a backup."
