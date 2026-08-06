#!/usr/bin/env bash
#
# Where the disk actually goes, and why a backup is the size it is.
#
# The n8n_data breakdown runs in a throwaway container against the volume, so it
# works whether or not the stack is up. The database section needs postgres
# running.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [[ -t 1 ]]; then
	BOLD=$'\e[1m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
	BOLD=''; DIM=''; OFF=''
fi

step() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$OFF"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }

volume_name() {
	docker compose config --format json 2>/dev/null \
		| python3 -c "import json,sys; print(json.load(sys.stdin)['volumes']['$1']['name'])" 2>/dev/null
}

step "Volumes"
docker system df -v 2>/dev/null \
	| awk '/^VOLUME NAME/ {print; next} /^(caddy_data|n8n_data|postgres_data)[[:space:]]/ {print}' \
	| sed 's/^/  /'
note "postgres_data holds the database; n8n_data the encryption key and binary data"

step "n8n_data — /home/node/.n8n"
N8N_VOLUME=$(volume_name n8n_data)
if [[ -n $N8N_VOLUME ]] && docker volume inspect "$N8N_VOLUME" >/dev/null 2>&1; then
	docker run --rm -v "$N8N_VOLUME:/src:ro" alpine sh -c '
		du -sh /src | sed "s#/src#TOTAL#"
		du -sh /src/* 2>/dev/null | sort -h | sed "s#/src/#  #"
		echo
		if [ -d /src/binaryData ]; then
			echo "binaryData files: $(find /src/binaryData -type f | wc -l)"
			echo "  payloads of retained executions; removed only when those are pruned"
		fi
		if [ -f /src/database.sqlite ]; then
			echo "database.sqlite is STILL PRESENT: $(du -h /src/database.sqlite | cut -f1)"
			echo "  the pre-Postgres database. Unused by this stack, but included in"
			echo "  every backup. Safe to delete once you no longer want its history."
		fi
	' 2>/dev/null | sed 's/^/  /'
else
	note "volume n8n_data not found"
fi

step "Database"
if docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
	docker compose exec -T postgres sh -c \
		'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' <<'SQL' 2>/dev/null | sed 's/^/  /'
select pg_size_pretty(pg_database_size(current_database())) as "total size";

select relname                                     as "table",
       pg_size_pretty(pg_total_relation_size(c.oid)) as "size",
       c.reltuples::bigint                         as "approx rows"
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by pg_total_relation_size(c.oid) desc
limit 10;
SQL
	note "execution_entity / execution_data dominating is normal: that is history,"
	note "governed by the EXECUTIONS_DATA_* keys in .env.dist"
else
	note "postgres is not running (make up) — skipping"
fi

echo
