#!/usr/bin/env bash
#
# Migrates a host that was deployed BEFORE .env was untracked, i.e. one where
# `git status` reports `modified: .env` and `modified: caddy_config/Caddyfile`.
#
# Run it from the OLD checkout:
#
#   cd /srv/n8n/n8n-docker-caddy
#   sudo bash /path/to/migrate-existing-host.sh
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
set -uo pipefail

OLD_DIR=$(pwd)
PARENT=$(dirname "$OLD_DIR")
NAME=$(basename "$OLD_DIR")
NEW_DIR="$PARENT/$NAME-next"
OLD_KEPT="$PARENT/$NAME-old"
BACKUP_DIR="$PARENT/migrate-backup-$(date +%Y%m%d-%H%M%S)"
BRANCH=${BRANCH:-main}

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

REMOTE=$(git remote get-url origin 2>/dev/null) || die "no 'origin' remote"
good "checkout: $OLD_DIR"
good "origin:   $REMOTE"

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

N8N_VERSION=$(docker compose exec -T n8n n8n --version 2>/dev/null | tr -d '\r')
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
if [[ -n $CUR_DATA_FOLDER ]]; then
	if [[ ${CUR_DATA_FOLDER%/} == "${OLD_DIR%/}" ]]; then
		good "DATA_FOLDER points at this checkout — dropping it is a no-op"
	else
		warn "DATA_FOLDER is '$CUR_DATA_FOLDER', NOT this checkout ($OLD_DIR)"
		note "real bind-mounted files live at that other path. Move them into the new"
		note "checkout, or set LOCAL_FILES_PATH in the new .env, before cutting over."
		confirm "Understood, continue?" || exit 0
	fi
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
cp -a caddy_config/Caddyfile "$BACKUP_DIR/Caddyfile.backup"
good "saved Caddyfile"

if docker compose exec -T postgres sh -c \
		'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > "$BACKUP_DIR/database.dump" 2>/dev/null \
		&& [[ -s $BACKUP_DIR/database.dump ]]; then
	good "saved database.dump ($(du -h "$BACKUP_DIR/database.dump" | cut -f1))"
else
	rm -f "$BACKUP_DIR/database.dump"
	warn "pg_dump failed (is postgres running?) — no database backup was taken"
	confirm "Continue WITHOUT a database backup?" || die "start the stack, then re-run"
fi

for v in n8n_data caddy_data; do
	if docker volume inspect "$v" >/dev/null 2>&1; then
		if docker run --rm -v "$v:/src:ro" -v "$BACKUP_DIR:/out" \
				alpine tar czf "/out/$v.tgz" -C /src . 2>/dev/null; then
			good "saved $v.tgz"
		else
			warn "could not archive volume $v"
		fi
	fi
done
note "n8n_data carries the encryption key; a database dump alone cannot decrypt"
note "credentials."

chmod 600 "$BACKUP_DIR"/* 2>/dev/null
info "backup contents:"
ls -l "$BACKUP_DIR" | sed 's/^/    /'

# ----------------------------------------------------------------- new checkout

step "New checkout next to the current one"

if [[ -d $NEW_DIR ]]; then
	good "$NEW_DIR already exists, updating it"
	git -C "$NEW_DIR" fetch origin "$BRANCH" --quiet \
		&& git -C "$NEW_DIR" checkout --quiet "$BRANCH" \
		&& git -C "$NEW_DIR" reset --hard --quiet "origin/$BRANCH" \
		&& good "updated to origin/$BRANCH"
else
	confirm "Clone $REMOTE ($BRANCH) into $NEW_DIR?" || exit 0
	git clone --branch "$BRANCH" "$REMOTE" "$NEW_DIR" || die "clone failed"
	good "cloned into $NEW_DIR"
fi

[[ -f "$NEW_DIR/.env.dist" ]] \
	|| die "$NEW_DIR/.env.dist not found — branch '$BRANCH' does not carry the migration yet"

# --------------------------------------------------------------- rebuild .env

step "Rebuild .env in the new checkout"

if [[ -f "$NEW_DIR/.env" ]]; then
	good ".env already present in $NEW_DIR, leaving it alone"
else
	# Carry every key the old .env set that the new template still knows about,
	# drop DATA_FOLDER, and pin COMPOSE_PROJECT_NAME to the observed project.
	python3 - "$BACKUP_DIR/env.backup" "$NEW_DIR/.env.dist" "$NEW_DIR/.env" "$PROJECT" <<'PY'
import re, sys

old_path, dist_path, out_path, project = sys.argv[1:5]
key_re = re.compile(r'^\s*#?\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$')
obsolete = {'DATA_FOLDER'}

old = {}
for line in open(old_path, encoding='utf-8'):
    if line.lstrip().startswith('#'):
        continue
    m = key_re.match(line)
    if m:
        old[m.group(1)] = m.group(2)

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
if leftovers:
    print('  kept unrecognised key(s): %s' % ', '.join(leftovers))
PY
	[[ -f "$NEW_DIR/.env" ]] || die "failed to build $NEW_DIR/.env"
	chown root:root "$NEW_DIR/.env" 2>/dev/null
	chmod 600 "$NEW_DIR/.env"
	good "wrote $NEW_DIR/.env (mode 600)"
	note "COMPOSE_PROJECT_NAME set to '$PROJECT' — this pins container identity"
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

info "dry run (resolves volumes without touching anything):"
if docker compose up -d --dry-run >/dev/null 2>&1; then
	good "dry run succeeded"
else
	docker compose up -d --dry-run 2>&1 | sed 's/^/    /'
	warn "dry run reported problems — read them before continuing"
	confirm "Continue anyway?" || { popd >/dev/null; exit 1; }
fi
popd >/dev/null

# --------------------------------------------------------------------- cutover

step "Cut over"

cat <<EOF
  This is the only step with downtime (roughly 15-30 seconds):

    1. docker compose down   in $OLD_DIR   (never with -v)
    2. mv $OLD_DIR -> $OLD_KEPT
    3. mv $NEW_DIR -> $OLD_DIR
    4. docker compose up -d  in the new checkout

  The data volumes are never touched, so rollback is instant:
    cd $OLD_DIR && docker compose down
    mv $OLD_DIR $NEW_DIR && mv $OLD_KEPT $OLD_DIR
    cd $OLD_DIR && docker compose up -d

EOF

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

# n8n runs as uid 1000; a root-owned local_files makes /files unwritable.
chown 1000:1000 local_files 2>/dev/null && good "local_files owned by uid 1000 (n8n)"

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

cat <<EOF

Still to check by hand:
  curl -sSI https://$EXPECTED_HOST/ | head -5
  openssl s_client -connect $EXPECTED_HOST:443 </dev/null 2>/dev/null \\
    | openssl x509 -noout -dates          # same certificate, not a reissue
  make logs S=n8n
  log in, open a workflow, confirm a credential decrypts, fire a test webhook

Backup:       $BACKUP_DIR
Old checkout: $OLD_KEPT   (keep it for a week, then remove)

Rollback:
  cd $OLD_DIR && docker compose down
  mv $OLD_DIR $NEW_DIR && mv $OLD_KEPT $OLD_DIR
  cd $OLD_DIR && docker compose up -d
EOF
