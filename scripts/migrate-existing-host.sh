#!/usr/bin/env bash
#
# Migrates a host that was deployed BEFORE .env was untracked, i.e. one where
# `git status` reports `modified: .env` and `modified: caddy_config/Caddyfile`.
#
# Run it from the OLD checkout, as the user that owns it — NOT with sudo:
#
#   cd /srv/n8n/n8n-docker-caddy
#   bash /path/to/migrate-existing-host.sh
#
# sudo would drop the SSH agent forwarded for that user, so the git clone from
# a git@github.com remote fails with 'Permission denied (publickey)'. Nothing
# here needs root: /srv is owned by the deploy user and n8n runs as uid 1000.
#
# It never runs a git merge. It clones the new revision next to the current
# checkout, carries the real .env across, verifies the result, and only then
# offers to swap the directories. Every destructive step asks first, and it is
# safe to re-run: each phase detects work already done.
#
# Why not just `git pull`: our commit DELETES .env from the index, and .env is
# locally modified with the only copy of the real database password. The pull
# aborts, and the reflex fix (git checkout / restore / stash / reset) destroys
# that password. See docs/DEPLOYMENT.md.
#
# A host still running the pre-Postgres revision (n8n on SQLite, no postgres
# service) is detected automatically: the database cannot be dumped, so the
# workflows and credentials are exported with n8n's CLI instead, and imported
# into the fresh Postgres database after the cutover with
# scripts/import-legacy-export.sh.
set -uo pipefail

BRANCH=postgres
REMOTE=
ALLOW_ROOT=0
DO_CUTOVER=1

usage() {
	cat <<'EOF'
Usage: bash migrate-existing-host.sh [options]

Run it from the deployed checkout, as the user that owns it.

  --branch <name>   revision to deploy (default: postgres, this fork's
                    deployment branch — main is still upstream's pre-Postgres
                    revision and carries none of this)
  --remote <url>    where to clone from (default: the old checkout's origin).
                    Needed when origin still points at n8n-io/n8n-docker-caddy,
                    which has no such branch.
  --allow-root      permit running as root, for a host where /srv really is
                    root-owned. Read the note at the top of this file first.
  --no-cutover      stop after verifying the new checkout, swap nothing.
  -h, --help        this message
EOF
}

while [[ $# -gt 0 ]]; do
	case $1 in
		--branch) [[ ${2:-} ]] || { usage; exit 1; }; BRANCH=$2; shift 2 ;;
		--remote) [[ ${2:-} ]] || { usage; exit 1; }; REMOTE=$2; shift 2 ;;
		--allow-root) ALLOW_ROOT=1; shift ;;
		--no-cutover) DO_CUTOVER=0; shift ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
	esac
done

OLD_DIR=$(pwd)
PARENT=$(dirname "$OLD_DIR")
NAME=$(basename "$OLD_DIR")
NEW_DIR="$PARENT/$NAME-next"
OLD_KEPT="$PARENT/$NAME-old"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$PARENT/migrate-backup-$STAMP"
EXPORT_REL="n8n-export-$STAMP"

if [[ -t 1 ]]; then
	BOLD=$'\e[1m'; RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
	BOLD=''; RED=''; YEL=''; GRN=''; DIM=''; OFF=''
fi

step()  { printf '\n%s=== %s ===%s\n' "$BOLD" "$1" "$OFF"; }
info()  { printf '  %s\n' "$1"; }
note()  { printf '  %s%s%s\n' "$DIM" "$1" "$OFF"; }
good()  { printf '  %sok%s %s\n' "$GRN" "$OFF" "$1"; }
warn()  { printf '  %swarn%s %s\n' "$YEL" "$OFF" "$1"; }
die()   { printf '\n%sabort:%s %s\n' "$RED" "$OFF" "$1" >&2; exit 1; }

confirm() {
	local answer
	read -r -p "  $1 [y/N] " answer </dev/tty
	[[ $answer == y || $answer == Y ]]
}

# ---------------------------------------------------------------- sanity checks

step "Checks"

[[ -f docker-compose.yml ]] || die "no docker-compose.yml here — run this from the deployed checkout"
[[ -d .git ]] || die "$OLD_DIR is not a git checkout"
command -v docker >/dev/null || die "docker not found"
command -v python3 >/dev/null || die "python3 not found (needed to rebuild .env)"

if [[ $EUID -eq 0 && $ALLOW_ROOT -eq 0 ]]; then
	die "run this as the user that owns $OLD_DIR, not with sudo.
  sudo resolves git against root's ~/.ssh and drops the SSH agent forwarded for
  your login, so cloning a git@github.com remote fails with
  'Permission denied (publickey)'.
  Nothing here needs root: the checkout's parent is owned by that user and n8n
  runs as uid 1000. If /srv really is root-owned on this host, re-run with
  --allow-root."
fi

docker info >/dev/null 2>&1 \
	|| die "cannot talk to the docker daemon as $(id -un). Add the user to the
  'docker' group (and re-login), rather than reaching for sudo."

[[ -w $PARENT ]] || die "$PARENT is not writable by $(id -un): the backup, the new
  checkout and the final swap all happen there."

if [[ -z $REMOTE ]]; then
	REMOTE=$(git remote get-url origin 2>/dev/null) \
		|| die "no 'origin' remote — pass --remote <url>"
fi
good "checkout: $OLD_DIR"
good "origin:   $REMOTE"

# Checked here, before the backup: discovering a wrong remote after tarring a
# multi-gigabyte volume wastes the operator's time for nothing.
if ! REMOTE_HEADS=$(git ls-remote --heads "$REMOTE" 2>&1); then
	warn "could not list the branches of $REMOTE"
	note "${REMOTE_HEADS%%$'\n'*}"
	confirm "Continue anyway (the clone would fail later)?" || exit 0
elif ! grep -qE "refs/heads/$BRANCH\$" <<<"$REMOTE_HEADS"; then
	die "branch '$BRANCH' does not exist on
    $REMOTE
  available there: $(grep -oE 'refs/heads/.*' <<<"$REMOTE_HEADS" | sed 's#refs/heads/##' | tr '\n' ' ')

  A checkout this old usually still points at upstream's n8n-io/n8n-docker-caddy,
  which carries none of this migration. Re-run with:
    --remote https://github.com/MakeMyWeb/n8n-docker-caddy.git"
else
	good "branch:   $BRANCH (present on that remote)"
fi

[[ -f .env ]] || die ".env not found. Nothing to carry across; deploy a fresh checkout instead."

if ! git ls-files --error-unmatch .env >/dev/null 2>&1; then
	warn "this checkout already looks migrated (.env is not tracked)"
	confirm "Continue anyway?" || exit 0
fi

# ------------------------------------------------------------------ read state

step "Current state (read-only)"

PROJECT=$(docker compose ps --format json 2>/dev/null | python3 -c '
import json, sys
names = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        parsed = json.loads(line)
    except ValueError:
        continue
    for item in (parsed if isinstance(parsed, list) else [parsed]):
        if isinstance(item, dict) and item.get("Project"):
            names.add(item["Project"])
print(next(iter(names)) if len(names) == 1 else "")
' 2>/dev/null)

if [[ -n $PROJECT ]]; then
	good "Compose project name: $PROJECT"
else
	PROJECT=$NAME
	warn "could not read the project name from running containers, assuming: $PROJECT"
	note "verify it yourself with: docker compose ps"
fi

# A pre-Postgres host keeps everything in SQLite inside the n8n_data volume.
# There is no database to dump and no password to carry: the data has to be
# exported through n8n's CLI and imported again after the cutover.
LEGACY=0
SERVICES=$(docker compose config --services 2>/dev/null)
if [[ -n $SERVICES ]]; then
	grep -qx postgres <<<"$SERVICES" || LEGACY=1
else
	grep -qE '^[[:space:]]*postgres:' docker-compose.yml || LEGACY=1
	warn "could not list the Compose services, fell back to reading docker-compose.yml"
fi

if [[ $LEGACY -eq 1 ]]; then
	printf '\n  %sThis host predates the Postgres migration.%s\n' "$BOLD" "$OFF"
	note "n8n stores everything in database.sqlite inside the n8n_data volume."
	note "This script will export the workflows and credentials with n8n's CLI,"
	note "start the new stack on an empty Postgres database, and then you run"
	note "scripts/import-legacy-export.sh once the owner account exists."
	note "Execution history, extra users and variables are NOT migrated."
	confirm "Understood, continue?" || exit 0
else
	good "this host already runs Postgres"
fi

# </dev/null throughout: `compose exec -T` still attaches stdin, and would eat
# the answers typed ahead of the confirmations below.
N8N_VERSION=$(docker compose exec -T n8n n8n --version </dev/null 2>/dev/null | tr -d '\r')
if [[ -n $N8N_VERSION ]]; then
	good "running n8n version: $N8N_VERSION"
	note "never pin N8N_IMAGE_TAG below this — n8n's DB migrations are not reversible"
else
	warn "could not read the n8n version (container down?)"
fi

env_get() {
	sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)\$/\1/p" "${2:-.env}" | tail -n1
}

CUR_DATA_FOLDER=$(env_get DATA_FOLDER)
DATA_FOLDER_ELSEWHERE=0
if [[ -n $CUR_DATA_FOLDER ]]; then
	if [[ ${CUR_DATA_FOLDER%/} == "${OLD_DIR%/}" ]]; then
		good "DATA_FOLDER points at this checkout — dropping it is a no-op"
	else
		DATA_FOLDER_ELSEWHERE=1
		warn "DATA_FOLDER is '$CUR_DATA_FOLDER', NOT this checkout ($OLD_DIR)"
		note "the bind-mounted files live at that other path. Their contents are"
		note "copied into the new checkout's local_files/ at cutover; set"
		note "LOCAL_FILES_PATH in the new .env instead if you want them left there."
		confirm "Understood, continue?" || exit 0
	fi
fi

# Where the directory currently mounted at /files actually lives on the host.
if [[ $DATA_FOLDER_ELSEWHERE -eq 1 ]]; then
	LOCAL_FILES_SRC="${CUR_DATA_FOLDER%/}/local_files"
else
	LOCAL_FILES_SRC="$OLD_DIR/local_files"
fi

# The parameterised Caddyfile derives the site address from SUBDOMAIN and
# DOMAIN_NAME. If the hand-edited hostname differs, Caddy would request a
# certificate for a different name and the site would go down.
EXPECTED_HOST="$(env_get SUBDOMAIN).$(env_get DOMAIN_NAME)"
LIVE_HOST=$(grep -vE '^[[:space:]]*(#|$)' caddy_config/Caddyfile 2>/dev/null \
	| sed -n -E '1s/^[[:space:]]*([^ {]+).*$/\1/p')

info "Caddyfile hostname in use: ${LIVE_HOST:-<none found>}"
info "derived from .env:         $EXPECTED_HOST"
if [[ -n $LIVE_HOST && $LIVE_HOST != "$EXPECTED_HOST" ]]; then
	warn "THESE DIFFER. After migration Caddy will serve $EXPECTED_HOST."
	note "fix SUBDOMAIN/DOMAIN_NAME in the new .env so they compose to $LIVE_HOST,"
	note "or accept the change knowingly."
	confirm "Continue?" || exit 0
else
	good "hostnames match"
fi

for v in caddy_data n8n_data postgres_data; do
	if docker volume inspect "$v" >/dev/null 2>&1; then
		good "volume $v exists"
	elif [[ $LEGACY -eq 1 && $v == postgres_data ]]; then
		note "volume postgres_data absent, as expected on a pre-Postgres host"
	else
		warn "volume $v not found — check 'docker volume ls' before cutting over"
	fi
done

if docker compose ps --status running --services 2>/dev/null | grep -q .; then
	warn "n8n is currently published on the host at 0.0.0.0:5678 (plain HTTP)"
	note "after migration it binds 127.0.0.1 only. If monitoring or a partner reaches"
	note "this host on port 5678, set N8N_HOST_PORT in the new .env accordingly."
fi

# ---------------------------------------------------------------------- backup

step "Backup (outside the checkout, before touching git)"

confirm "Create a full backup in $BACKUP_DIR?" || die "a backup is not optional here"

install -d -m 700 "$BACKUP_DIR" || die "could not create $BACKUP_DIR"

cp -a .env "$BACKUP_DIR/env.backup" || die "could not copy .env"
good "saved .env  <- the ONLY copy of the real password"
cp -a caddy_config/Caddyfile "$BACKUP_DIR/Caddyfile.backup" || warn "could not copy the Caddyfile"

if [[ $LEGACY -eq 0 ]]; then
	if docker compose exec -T postgres sh -c \
			'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
			</dev/null > "$BACKUP_DIR/database.dump" 2>/dev/null \
			&& [[ -s $BACKUP_DIR/database.dump ]]; then
		good "saved database.dump ($(du -h "$BACKUP_DIR/database.dump" | cut -f1))"
	else
		rm -f "$BACKUP_DIR/database.dump"
		warn "pg_dump failed (is postgres running?) — no database backup was taken"
		confirm "Continue WITHOUT a database backup?" || die "start the stack, then re-run"
	fi
else
	# The SQLite database itself travels inside n8n_data.tgz below. What cannot
	# be recovered from it later is a CLI export, and that needs n8n running.
	docker compose ps --status running --services 2>/dev/null | grep -qx n8n \
		|| die "n8n is not running. Start the old stack (docker compose up -d):
  exporting the workflows and credentials needs its CLI."

	EXPORT_HOST_DIR="$LOCAL_FILES_SRC/$EXPORT_REL"
	mkdir -p "$EXPORT_HOST_DIR/workflows" "$EXPORT_HOST_DIR/credentials" \
		|| die "could not create $EXPORT_HOST_DIR"

	info "exporting through n8n's CLI into $EXPORT_HOST_DIR"
	docker compose exec -T n8n \
		n8n export:workflow --backup --output="/files/$EXPORT_REL/workflows/" </dev/null \
		|| die "export:workflow failed — read the output above"
	# No --decrypted: the values stay encrypted, and the new stack reuses the
	# same n8n_data volume, hence the same encryption key.
	docker compose exec -T n8n \
		n8n export:credentials --backup --output="/files/$EXPORT_REL/credentials/" </dev/null \
		|| die "export:credentials failed — read the output above"

	docker compose exec -T n8n sh -c 'sha256sum /home/node/.n8n/config' </dev/null 2>/dev/null \
		| awk '{print $1}' > "$EXPORT_HOST_DIR/encryption-key.sha256"
	[[ -s $EXPORT_HOST_DIR/encryption-key.sha256 ]] \
		|| die "could not fingerprint the encryption key at /home/node/.n8n/config"

	W_COUNT=$(find "$EXPORT_HOST_DIR/workflows" -name '*.json' | wc -l)
	C_COUNT=$(find "$EXPORT_HOST_DIR/credentials" -name '*.json' | wc -l)
	good "exported $W_COUNT workflow(s) and $C_COUNT credential(s)"
	[[ $W_COUNT -gt 0 ]] || confirm "Zero workflows exported. Continue anyway?" \
		|| die "nothing to migrate — check 'docker compose logs n8n'"
	note "the export travels with local_files/ at cutover; a copy also goes in the backup"
	cp -a "$EXPORT_HOST_DIR" "$BACKUP_DIR/$EXPORT_REL" || warn "could not copy the export into the backup"
fi

for v in n8n_data caddy_data; do
	if docker volume inspect "$v" >/dev/null 2>&1; then
		# The container runs as root, so it owns whatever it writes into the bind
		# mount; hand it back to the caller.
		if docker run --rm -v "$v:/src:ro" -v "$BACKUP_DIR:/out" alpine sh -c \
				"tar czf /out/$v.tgz -C /src . && chown $(id -u):$(id -g) /out/$v.tgz" 2>/dev/null; then
			good "saved $v.tgz ($(du -h "$BACKUP_DIR/$v.tgz" | cut -f1))"
		else
			warn "could not archive volume $v"
		fi
	fi
done
note "n8n_data carries the encryption key; a database dump alone cannot decrypt"
note "credentials."
[[ $LEGACY -eq 1 ]] && note "n8n_data.tgz also holds database.sqlite, i.e. the execution history"

find "$BACKUP_DIR" -type d -exec chmod 700 {} + 2>/dev/null
find "$BACKUP_DIR" -type f -exec chmod 600 {} + 2>/dev/null
info "backup contents:"
ls -l "$BACKUP_DIR" | sed 's/^/    /'

# ----------------------------------------------------------------- new checkout

step "New checkout next to the current one"

if [[ -d $NEW_DIR ]]; then
	good "$NEW_DIR already exists, updating it"
	git -C "$NEW_DIR" remote set-url origin "$REMOTE" \
		&& git -C "$NEW_DIR" fetch origin "$BRANCH" --quiet \
		&& git -C "$NEW_DIR" checkout -q -B "$BRANCH" "origin/$BRANCH" \
		|| die "could not update $NEW_DIR to $BRANCH from $REMOTE"
	good "updated to origin/$BRANCH"
else
	confirm "Clone $REMOTE ($BRANCH) into $NEW_DIR?" || exit 0
	git clone --branch "$BRANCH" "$REMOTE" "$NEW_DIR" || die "clone failed — read git's
  message above; the two usual ones are:
    'Remote branch $BRANCH not found'  -> wrong repository, pass
        --remote https://github.com/MakeMyWeb/n8n-docker-caddy.git
    'Permission denied (publickey)'    -> you are running as $(id -un); check
        'ssh -T git@github.com', and do not use sudo (it drops the forwarded
        agent). An https:// --remote also sidesteps SSH entirely."
	good "cloned into $NEW_DIR"
fi

[[ -f "$NEW_DIR/.env.dist" ]] \
	|| die "$NEW_DIR/.env.dist not found — branch '$BRANCH' does not carry the migration.
  This fork deploys from 'postgres'; 'main' is still upstream's pre-Postgres
  revision. Remove $NEW_DIR and re-run with --branch postgres."

if [[ $LEGACY -eq 1 ]] && ! docker volume inspect postgres_data >/dev/null 2>&1; then
	info "the new stack needs a postgres_data volume (declared external, so"
	info "Compose will not create it silently)"
	confirm "Create the empty postgres_data volume?" \
		|| die "preflight cannot pass without it"
	docker volume create postgres_data >/dev/null || die "could not create postgres_data"
	good "created postgres_data — empty on purpose, n8n initialises it on first start"
fi

# --------------------------------------------------------------- rebuild .env

step "Rebuild .env in the new checkout"

if [[ -f "$NEW_DIR/.env" ]]; then
	good ".env already present in $NEW_DIR, leaving it alone"
else
	# Values that do not come from the old .env. Passed as a mode-600 file, not
	# on the command line, so the generated password never shows up in `ps`.
	OVERRIDES="$BACKUP_DIR/env-overrides"
	: > "$OVERRIDES" && chmod 600 "$OVERRIDES" || die "could not write $OVERRIDES"

	if [[ $LEGACY -eq 1 ]]; then
		command -v openssl >/dev/null || die "openssl not found (needed to generate POSTGRES_PASSWORD)"
		printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -base64 36 | tr -d '\n')" >> "$OVERRIDES"
		# Import on the version the export came from; upgrade afterwards, as a
		# separate deliberate step.
		if [[ -n $N8N_VERSION ]] \
				&& docker manifest inspect "docker.n8n.io/n8nio/n8n:$N8N_VERSION" >/dev/null 2>&1; then
			printf 'N8N_IMAGE_TAG=%s\n' "$N8N_VERSION" >> "$OVERRIDES"
		else
			warn "could not confirm the image tag docker.n8n.io/n8nio/n8n:${N8N_VERSION:-?}"
			note "N8N_IMAGE_TAG stays unset, so the new stack pulls 'latest'. Pin it by"
			note "hand in $NEW_DIR/.env if you want the exact current version."
		fi
	fi

	# Carry every key the old .env set that the new template still knows about,
	# drop DATA_FOLDER, and pin COMPOSE_PROJECT_NAME to the observed project.
	python3 - "$BACKUP_DIR/env.backup" "$NEW_DIR/.env.dist" "$NEW_DIR/.env" "$PROJECT" "$OVERRIDES" <<'PY'
import re, sys

old_path, dist_path, out_path, project, overrides_path = sys.argv[1:6]
key_re = re.compile(r'^\s*#?\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$')
obsolete = {'DATA_FOLDER'}


def read_env(path):
    values = {}
    for line in open(path, encoding='utf-8'):
        if line.lstrip().startswith('#'):
            continue
        m = key_re.match(line)
        if m:
            values[m.group(1)] = m.group(2)
    return values


old = read_env(old_path)
overrides = read_env(overrides_path)
old.update(overrides)

out, carried = [], set()
for line in open(dist_path, encoding='utf-8'):
    m = key_re.match(line)
    if not m:
        out.append(line)
        continue
    key = m.group(1)
    if key in obsolete:
        continue
    if key == 'COMPOSE_PROJECT_NAME':
        out.append('COMPOSE_PROJECT_NAME=%s\n' % project)
        carried.add(key)
    elif key in old:
        # Uncomments optional keys that the old .env actually set.
        out.append('%s=%s\n' % (key, old[key]))
        carried.add(key)
    else:
        out.append(line)

leftovers = sorted(k for k in old if k not in carried and k not in obsolete)
if leftovers:
    out.append('\n# Carried over from the previous .env, absent from .env.dist:\n')
    out += ['%s=%s\n' % (k, old[k]) for k in leftovers]

open(out_path, 'w', encoding='utf-8').write(''.join(out))
dropped = sorted(obsolete & set(old))
print('  carried %d key(s); dropped: %s' % (len(carried), ', '.join(dropped) or 'none'))
if overrides:
    print('  generated: %s' % ', '.join(sorted(overrides)))
if leftovers:
    print('  kept unrecognised key(s): %s' % ', '.join(leftovers))
PY
	[[ -f "$NEW_DIR/.env" ]] || die "failed to build $NEW_DIR/.env"
	chmod 600 "$NEW_DIR/.env"
	good "wrote $NEW_DIR/.env (mode 600, owned by $(id -un))"
	note "COMPOSE_PROJECT_NAME set to '$PROJECT' — this pins container identity"
	[[ $LEGACY -eq 1 ]] \
		&& note "the generated POSTGRES_PASSWORD exists only there and in $BACKUP_DIR"
fi

mkdir -p "$NEW_DIR/backups"

# ---------------------------------------------------------------- verification

step "Verify the new checkout (nothing is mutated)"

pushd "$NEW_DIR" >/dev/null || die "cannot enter $NEW_DIR"
chmod +x scripts/*.sh 2>/dev/null

if ./scripts/preflight.sh; then
	good "preflight passed"
else
	warn "preflight reported errors (above)"
	note "fix $NEW_DIR/.env then re-run this script; nothing has been swapped yet"
	popd >/dev/null
	exit 1
fi

info "interpolated config:"
docker compose config 2>/dev/null \
	| grep -E '^[[:space:]]+(image|name|host_ip|published|external):' | sed 's/^/    /'

# Downloading images mutates nothing, and it has to happen before the dry run:
# --dry-run only *pretends* to pull, then reports 'No such image' for a tag that
# is not local yet. It also shortens the cutover, which is the part with downtime.
info "pulling the images (changes nothing on the running stack):"
if docker compose pull --quiet 2>&1 | sed 's/^/    /'; then
	good "images present locally"
else
	warn "could not pull every image — the dry run below may complain about it"
fi

info "dry run (resolves volumes without touching anything):"
if docker compose up -d --dry-run >/dev/null 2>&1; then
	good "dry run succeeded"
else
	docker compose up -d --dry-run 2>&1 | sed 's/^/    /'
	warn "dry run reported problems — read them before continuing"
	confirm "Continue anyway?" || { popd >/dev/null; exit 1; }
fi
popd >/dev/null

if [[ $DO_CUTOVER -eq 0 ]]; then
	step "Stopping before the cutover, as asked"
	info "the verified checkout is ready at $NEW_DIR"
	info "re-run without --no-cutover to swap it in"
	exit 0
fi

# --------------------------------------------------------------------- cutover

step "Cut over"

cat <<EOF
  This is the only step with downtime (roughly 15-30 seconds):

    1. docker compose down   in $OLD_DIR   (never with -v)
    2. mv $OLD_DIR -> $OLD_KEPT
    3. mv $NEW_DIR -> $OLD_DIR
    4. copy local_files/ across, then docker compose up -d

  The data volumes are never touched, so rollback is instant:
    cd $OLD_DIR && docker compose down
    mv $OLD_DIR $NEW_DIR && mv $OLD_KEPT $OLD_DIR
    cd $OLD_DIR && docker compose up -d

EOF

if [[ $LEGACY -eq 1 ]]; then
	cat <<EOF
  On this host the new stack starts on an EMPTY Postgres database. Rollback stays
  free until you run scripts/import-legacy-export.sh and start using n8n again.

EOF
fi

[[ -e $OLD_KEPT ]] && die "$OLD_KEPT already exists — move it aside first"

confirm "Cut over now?" || {
	info "stopping here. The new checkout is ready at $NEW_DIR;"
	info "re-run this script when you want to cut over."
	exit 0
}

info "stopping the current stack..."
( cd "$OLD_DIR" && docker compose down ) || die "docker compose down failed"

info "swapping directories..."
mv "$OLD_DIR" "$OLD_KEPT" || die "could not move $OLD_DIR aside"
if ! mv "$NEW_DIR" "$OLD_DIR"; then
	mv "$OLD_KEPT" "$OLD_DIR"
	die "could not move the new checkout into place — rolled back, stack is DOWN. Start it with: cd $OLD_DIR && docker compose up -d"
fi
good "new checkout is now at $OLD_DIR"

cd "$OLD_DIR" || die "cannot enter $OLD_DIR"

# local_files/* is gitignored, so the clone arrives with nothing but .gitkeep.
# Copy, never move: the old checkout has to stay intact for the rollback.
if [[ $DATA_FOLDER_ELSEWHERE -eq 0 ]]; then
	LOCAL_FILES_SRC="$OLD_KEPT/local_files"
fi
if [[ -d $LOCAL_FILES_SRC ]]; then
	LF_COUNT=$(find "$LOCAL_FILES_SRC" -mindepth 1 ! -name .gitkeep | wc -l)
	if [[ $LF_COUNT -gt 0 ]]; then
		if cp -a "$LOCAL_FILES_SRC/." local_files/; then
			good "copied $LF_COUNT entr(y|ies) from $LOCAL_FILES_SRC into local_files/"
		else
			warn "could not copy $LOCAL_FILES_SRC into local_files/ — /files will be incomplete"
		fi
	else
		note "$LOCAL_FILES_SRC is empty, nothing to carry across"
	fi
else
	warn "$LOCAL_FILES_SRC not found — nothing carried into local_files/"
fi

# n8n runs as uid 1000; a local_files it cannot write to makes /files read-only.
LF_UID=$(stat -c %u local_files 2>/dev/null)
if [[ -n $LF_UID && $LF_UID != 1000 ]]; then
	if chown -R 1000:1000 local_files 2>/dev/null; then
		good "local_files owned by uid 1000 (n8n)"
	else
		warn "local_files is owned by uid $LF_UID; n8n (uid 1000) cannot write to /files"
		note "fix it with: sudo chown -R 1000:1000 $OLD_DIR/local_files"
	fi
else
	good "local_files already owned by uid 1000 (n8n)"
fi

info "starting the stack..."
docker compose up -d || die "startup failed. Roll back with the commands above."

# ------------------------------------------------------------------ post-checks

step "Result"

docker compose ps

echo
if [[ -z $(git status --porcelain) ]]; then
	good "git status is clean — this was the whole point"
else
	warn "git status is NOT clean:"
	git status --short | sed 's/^/    /'
fi

if [[ -d "$OLD_KEPT/caddy_config/caddy" ]]; then
	info "the old checkout still holds root-owned Caddy state; remove it with:"
	note "sudo rm -rf $OLD_KEPT/caddy_config/caddy"
fi

if [[ $LEGACY -eq 1 ]]; then
	cat <<EOF

The database is empty. Two steps left, in this order:

  1. https://$EXPECTED_HOST/setup
     Create the owner account (reuse the same e-mail if you like — the old
     accounts lived in SQLite and are not migrated). n8n attaches imported
     workflows and credentials to that account, so it must exist first.

  2. cd $OLD_DIR && ./scripts/import-legacy-export.sh
     Imports local_files/$EXPORT_REL. Every imported workflow arrives
     DEACTIVATED: re-enable them by hand once you have checked them.

Then verify:
  make logs S=n8n
  open a credential — it decrypting proves the encryption key was reused
  fire one test webhook (URLs are unchanged: same domain, same ids)
EOF
else
	cat <<EOF

Still to check by hand:
  curl -sSI https://$EXPECTED_HOST/ | head -5
  openssl s_client -connect $EXPECTED_HOST:443 </dev/null 2>/dev/null \\
    | openssl x509 -noout -dates          # same certificate, not a reissue
  make logs S=n8n
  log in, open a workflow, confirm a credential decrypts, fire a test webhook
EOF
fi

cat <<EOF

Backup:       $BACKUP_DIR
Old checkout: $OLD_KEPT   (keep it for a week, then remove)

Rollback:
  cd $OLD_DIR && docker compose down
  mv $OLD_DIR $NEW_DIR && mv $OLD_KEPT $OLD_DIR
  cd $OLD_DIR && docker compose up -d
EOF
