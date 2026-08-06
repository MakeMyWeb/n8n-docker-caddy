#!/usr/bin/env bash
#
# Second half of the SQLite -> Postgres migration: imports the CLI export that
# scripts/migrate-existing-host.sh took from the old instance into the fresh
# Postgres database.
#
#   ./scripts/import-legacy-export.sh [local_files/n8n-export-<stamp>] [--force]
#
# With no argument it picks the newest local_files/n8n-export-* directory.
#
# It must run AFTER the owner account exists: n8n attaches imported workflows
# and credentials to the instance owner's personal project, and there is no CLI
# to create that account. Open https://<your-host>/setup first.
#
# The credentials in the export are still encrypted. They only decrypt because
# the n8n_data volume — and with it /home/node/.n8n/config, the encryption key —
# is reused as is; the fingerprint recorded at export time is verified below.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

FORCE=0
SRC=

while [[ $# -gt 0 ]]; do
	case $1 in
		--force) FORCE=1; shift ;;
		-h|--help)
			sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
			exit 0 ;;
		-*) echo "unknown option: $1" >&2; exit 1 ;;
		*) SRC=$1; shift ;;
	esac
done

if [[ -t 1 ]]; then
	BOLD=$'\e[1m'; RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
	BOLD=''; RED=''; YEL=''; GRN=''; DIM=''; OFF=''
fi

step() { printf '\n%s=== %s ===%s\n' "$BOLD" "$1" "$OFF"; }
info() { printf '  %s\n' "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }
good() { printf '  %sok%s %s\n' "$GRN" "$OFF" "$1"; }
warn() { printf '  %swarn%s %s\n' "$YEL" "$OFF" "$1"; }
die()  { printf '\n%sabort:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

env_get() {
	sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)\$/\1/p" .env | tail -n1
}

# The query is single-quoted inside the container shell so that SQL identifiers
# can carry double quotes; it must therefore contain no single quote itself —
# write string literals dollar-quoted ($$like this$$), from a single-quoted shell
# variable so that $$ is not read as the shell's PID.
# </dev/null because `compose exec -T` attaches stdin even when the command has
# no use for it.
# Ends in `|| true`: under `set -e` with pipefail, a failing query inside $(…)
# would abort the whole script with no message at all. An empty answer lets the
# caller say something useful instead.
psql_value() {
	docker compose exec -T postgres sh -c \
		"psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc '$1'" </dev/null 2>/dev/null \
		| tr -d '\r' || true
}

step "Checks"

[[ -f .env ]] || die ".env not found — run this from the deployed checkout"

if [[ $EUID -eq 0 ]]; then
	die "run this as the user that owns the checkout, not with sudo: it would
  leave root-owned files behind in local_files/ and in the repository."
fi

# The export has to be visible from inside the container, i.e. under whatever
# directory is mounted at /files.
FILES_HOST_DIR=$(env_get LOCAL_FILES_PATH)
FILES_HOST_DIR=$(realpath -m "${FILES_HOST_DIR:-./local_files}")

if [[ -z $SRC ]]; then
	SRC=$(find "$FILES_HOST_DIR" -maxdepth 1 -type d -name 'n8n-export-*' \
		| sort | tail -n1)
	[[ -n $SRC ]] || die "no n8n-export-* directory found in $FILES_HOST_DIR.
  Pass the path explicitly, or copy the export out of the migration backup."
fi
SRC=$(realpath -m "$SRC")
[[ $SRC != "$FILES_HOST_DIR" ]] \
	|| die "pass the export directory itself (e.g. local_files/n8n-export-…), not $FILES_HOST_DIR"

case $SRC/ in
	"$FILES_HOST_DIR"/*) REL=${SRC#"$FILES_HOST_DIR"/} ;;
	*) die "$SRC is not under $FILES_HOST_DIR, which is what the container sees
  as /files. Move it there first." ;;
esac
CONTAINER_SRC="/files/$REL"

[[ -d $SRC/workflows ]]   || die "$SRC/workflows not found"
[[ -d $SRC/credentials ]] || die "$SRC/credentials not found"

W_FILES=$(find "$SRC/workflows" -maxdepth 1 -name '*.json' | wc -l)
C_FILES=$(find "$SRC/credentials" -maxdepth 1 -name '*.json' | wc -l)
good "export: $SRC"
good "seen by n8n as: $CONTAINER_SRC"
good "$W_FILES workflow file(s), $C_FILES credential file(s)"
[[ $W_FILES -gt 0 || $C_FILES -gt 0 ]] || die "nothing to import"

RUNNING=$(docker compose ps --status running --services 2>/dev/null || true)
grep -qx n8n <<<"$RUNNING"      || die "the n8n service is not running (make up)"
grep -qx postgres <<<"$RUNNING" || die "the postgres service is not running (make up)"
good "n8n and postgres are running"

# The encryption key must be the one the credentials were encrypted with.
KEY_FILE="$SRC/encryption-key.sha256"
if [[ -f $KEY_FILE ]]; then
	EXPECTED_KEY=$(tr -d ' \t\r\n' < "$KEY_FILE")
	CURRENT_KEY=$(docker compose exec -T n8n sh -c 'sha256sum /home/node/.n8n/config' \
		</dev/null 2>/dev/null | awk '{print $1}')
	[[ -n $CURRENT_KEY ]] || die "could not read /home/node/.n8n/config in the n8n container"
	if [[ $CURRENT_KEY != "$EXPECTED_KEY" ]]; then
		die "the encryption key changed since the export was taken.
  Imported credentials would be impossible to decrypt. The key lives in the
  n8n_data volume at /home/node/.n8n/config — restore the one from the
  migration backup (n8n_data.tgz) before importing."
	fi
	good "encryption key matches the one used at export time"
else
	warn "no encryption-key.sha256 next to the export — cannot verify the key"
	note "if the n8n_data volume was recreated, the credentials will not decrypt"
fi

# Imports attach to the instance owner's personal project. Counting rows in
# "user" proves nothing: n8n seeds a placeholder owner at first start, so the
# table is never empty. Its own flag is what says the setup screen was completed.
# shellcheck disable=SC2016  # the $$ must reach psql literally, hence no expansion
SETUP_QUERY='select value from settings where key = $$userManagement.isInstanceOwnerSetUp$$'
OWNER_SETUP=$(psql_value "$SETUP_QUERY")

if [[ -z $OWNER_SETUP ]]; then
	if [[ ! $(psql_value 'select 1') =~ 1 ]]; then
		die "could not query the n8n database. Is it still running its migrations?
  Check: make logs S=n8n"
	fi
	warn "could not read userManagement.isInstanceOwnerSetUp — unknown schema"
	note "carrying on; the import itself fails loudly if there is no owner project"
elif [[ $OWNER_SETUP != true ]]; then
	HOST="$(env_get SUBDOMAIN).$(env_get DOMAIN_NAME)"
	die "the owner account has not been created yet. Open https://$HOST/setup and
  create it first — imported workflows and credentials are attached to its
  personal project, and no CLI can create that account.
  (n8n pre-creates an empty owner row, so do not go by the login page alone.)"
else
	good "the owner account is set up"
fi

W_BEFORE=$(psql_value 'select count(*) from workflow_entity')
C_BEFORE=$(psql_value 'select count(*) from credentials_entity')
info "database currently holds $W_BEFORE workflow(s) and $C_BEFORE credential(s)"

if [[ ${W_BEFORE:-0} -gt 0 || ${C_BEFORE:-0} -gt 0 ]] && [[ $FORCE -eq 0 ]]; then
	die "the database is not empty — this import has probably already run.
  Re-importing would duplicate or overwrite entries by id. Use --force if you
  really mean it."
fi

# ---------------------------------------------------------------------- import

step "Import"

# Credentials first, so the nodes of each workflow resolve theirs on arrival.
if [[ $C_FILES -gt 0 ]]; then
	info "importing credentials..."
	docker compose exec -T n8n \
		n8n import:credentials --separate --input="$CONTAINER_SRC/credentials/" </dev/null \
		|| die "import:credentials failed — read the output above"
fi

if [[ $W_FILES -gt 0 ]]; then
	info "importing workflows..."
	docker compose exec -T n8n \
		n8n import:workflow --separate --input="$CONTAINER_SRC/workflows/" </dev/null \
		|| die "import:workflow failed — read the output above"
fi

# ------------------------------------------------- workflow history backfill
#
# This import deliberately runs on the version the export came from, and older
# n8n releases' import:workflow writes workflow_entity.versionId WITHOUT the
# matching row in workflow_history. Nothing notices until something sets
# workflow_entity.activeVersionId, which is constrained by
#
#   FOREIGN KEY ("activeVersionId") REFERENCES workflow_history("versionId")
#
# Two things do exactly that: activating a workflow, and the
# ActivateExecuteWorkflowTriggerWorkflows migration of a later upgrade — which
# runs before n8n serves traffic, so the failure is a crash loop, and `make
# upgrade` cannot roll it back. One snapshot per current version closes the gap.
# Recent versions create these rows themselves, so this is then a no-op.

step "Workflow history"

read -r -d '' BACKFILL_SQL <<'SQL' || true
INSERT INTO workflow_history ("versionId", "workflowId", authors, nodes, connections)
SELECT w."versionId", w.id, 'legacy import backfill', w.nodes, w.connections
FROM workflow_entity w
WHERE w."versionId" IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM workflow_history h WHERE h."versionId" = w."versionId");
SQL

if BACKFILL_OUT=$(printf '%s' "$BACKFILL_SQL" | docker compose exec -T postgres sh -c \
		'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -tA -f -' 2>&1); then
	# psql answers "INSERT 0 <n>"
	good "backfilled ${BACKFILL_OUT##* } missing workflow_history row(s)"
	note "without them, activating an imported workflow — or the next upgrade's"
	note "ActivateExecuteWorkflowTriggerWorkflows migration — fails on a foreign key"
else
	warn "could not backfill workflow_history"
	note "${BACKFILL_OUT}"
	note "activating an imported workflow may fail on the activeVersionId foreign"
	note "key, and so may the next 'make upgrade'. Sort this out before upgrading."
fi

step "Result"

W_AFTER=$(psql_value 'select count(*) from workflow_entity')
C_AFTER=$(psql_value 'select count(*) from credentials_entity')

printf '  workflows:   %s in the export -> %s in the database\n' "$W_FILES" "$W_AFTER"
printf '  credentials: %s in the export -> %s in the database\n' "$C_FILES" "$C_AFTER"

[[ ${W_AFTER:-0} -ge $W_FILES ]] || warn "fewer workflows than files — check the output above"
[[ ${C_AFTER:-0} -ge $C_FILES ]] || warn "fewer credentials than files — check the output above"

HOST="$(env_get SUBDOMAIN).$(env_get DOMAIN_NAME)"
cat <<EOF

Now, in the UI at https://$HOST/ :

  * Every imported workflow is DEACTIVATED. n8n's import deactivates them on
    purpose, so nothing fires behind your back. Re-enable them one by one once
    you have checked them; their webhook URLs are unchanged (same domain, same
    workflow and node ids).
  * Open one credential and confirm it shows its secret. That proves the reused
    encryption key matches, and is the single most important check here.

Not migrated, by design: execution history, the previous user accounts,
variables and insights. They are still readable in the old SQLite database,
kept inside n8n_data.tgz in the migration backup.

Once you are satisfied:
  make backup            # first backup of the Postgres-based deployment
  make upgrade           # only then move off the pinned N8N_IMAGE_TAG
EOF
