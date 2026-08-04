# Deployment and migration runbook

Two situations:

- **[Fresh host](#fresh-host)** — nothing deployed yet.
- **[Migrating an existing deployment](#migrating-an-existing-deployment)** — a server running a
  revision from before `.env` was untracked, where `git status` shows `modified: .env` and
  `modified: caddy_config/Caddyfile`. **Read this before running `git pull` there.**

---

## Fresh host

```bash
sudo install -d -o "$USER" /srv/n8n
cd /srv/n8n
git clone https://github.com/MakeMyWeb/n8n-docker-caddy.git
cd n8n-docker-caddy

make init                 # data volumes + .env from .env.dist, mode 600
make secret               # copy the output into POSTGRES_PASSWORD
$EDITOR .env              # DOMAIN_NAME, SUBDOMAIN, SSL_EMAIL, POSTGRES_PASSWORD
make preflight            # DNS, ports, placeholders, Compose config, Caddyfile
make up
make logs
```

The DNS `A` record for `${SUBDOMAIN}.${DOMAIN_NAME}` must already point at the host: Let's Encrypt
validates over HTTP on port 80 and will fail otherwise. `make preflight` compares the record against
the host's public IP and warns when they differ.

Then verify:

```bash
curl -sSI "https://${SUBDOMAIN}.${DOMAIN_NAME}/" | head -5
git status --porcelain        # must be empty
```

---

## Migrating an existing deployment

### Why `git pull` is the wrong move

The migration commit **deletes `.env` from the index**. On the server that same file is locally
modified and holds the only copy of the real database password. So:

```
error: Your local changes to the following files would be overwritten by merge:
        .env
Please commit your changes or stash them before you merge.
```

The pull aborts and nothing is lost *yet*. The danger is the next reflex — `git checkout -- .env`,
`git restore .env`, `git stash`, `git reset --hard`. **All four destroy the password**, because it
exists nowhere except in that working-tree modification. `caddy_config/Caddyfile` is in the same
state, so it hits the same wall.

The rule: **back up outside the working tree before any git command, and never `stash` or `checkout`
a file whose only source of truth is the local modification.**

### Assisted procedure

`scripts/migrate-existing-host.sh` performs the steps below with a confirmation at every destructive
one. It never runs a merge, it is safe to re-run, and it stops before the cutover if anything looks
wrong. Copy it onto the server and run it **from the old checkout**:

```bash
cd /srv/n8n/n8n-docker-caddy
sudo bash /path/to/migrate-existing-host.sh
```

It reads the current state, takes a full backup outside the repo, clones the new revision into
`../n8n-docker-caddy-next`, rebuilds `.env` from the old one plus `.env.dist` (dropping
`DATA_FOLDER`, pinning `COMPOSE_PROJECT_NAME` to the observed project name), runs preflight and a
`--dry-run`, then offers the directory swap.

The manual equivalent follows, in case you prefer to drive it yourself.

### Step 0 — read the current state (read-only)

```bash
cd /srv/n8n/n8n-docker-caddy

docker compose ps                        # note the container name prefix -> COMPOSE_PROJECT_NAME
docker compose exec n8n n8n --version    # note the version -> NEVER pin below it
docker compose images                    # note the caddy/postgres tags actually running
grep DATA_FOLDER .env                    # must point at this checkout
grep -v '^#' caddy_config/Caddyfile      # the hostname must equal ${SUBDOMAIN}.${DOMAIN_NAME}
ls caddy_config/                         # any other Caddy files being imported?
docker volume ls | grep -E 'caddy_data|n8n_data|postgres_data'
```

Three things to reconcile before going further:

- **`COMPOSE_PROJECT_NAME`** must equal the prefix you just read. Get it wrong and the first `up`
  creates a parallel set of containers while treating the live ones as orphans.
- **The Caddyfile hostname** must equal `${SUBDOMAIN}.${DOMAIN_NAME}` from `.env`. The new Caddyfile
  derives its site address from those two variables; if the hand-edited hostname differs, Caddy
  requests a certificate for a different name and the site goes down.
- **`DATA_FOLDER`** normally points at the checkout, in which case dropping it changes nothing. If it
  points elsewhere, real bind-mounted files live at that other path — move them, or set
  `LOCAL_FILES_PATH` in the new `.env`.

### Step 1 — back up, outside the repo, before touching git

```bash
B=/srv/n8n/backup-$(date +%F); sudo install -d -m 700 "$B"

sudo cp -a .env "$B/env.backup"                      # the ONLY copy of the real password
sudo cp -a caddy_config/Caddyfile "$B/Caddyfile.backup"

docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
  | sudo tee "$B/database.dump" >/dev/null
docker run --rm -v n8n_data:/src:ro   -v "$B":/out alpine tar czf /out/n8n_data.tgz   -C /src .
docker run --rm -v caddy_data:/src:ro -v "$B":/out alpine tar czf /out/caddy_data.tgz -C /src .

sudo chmod 600 "$B"/*
ls -l "$B"
```

`n8n_data` carries the encryption key. A database dump without it restores workflows whose
credentials can never be decrypted.

### Step 2 — new checkout alongside the current one

```bash
cd /srv/n8n
sudo git clone -b main https://github.com/MakeMyWeb/n8n-docker-caddy.git n8n-docker-caddy-next
cd n8n-docker-caddy-next

sudo cp "$B/env.backup" .env
sudo chown root:root .env && sudo chmod 600 .env
```

Reconcile `.env` against `.env.dist`:

- add `COMPOSE_PROJECT_NAME=` with the value from step 0
- remove `DATA_FOLDER` (obsolete: paths are now relative to the checkout)
- optionally set the `*_IMAGE_TAG` keys to the versions observed in step 0, to pin them

Then verify, without mutating anything:

```bash
sudo -E make env-check
sudo -E make preflight
docker compose config | grep -E 'image:|external:|host_ip|published'
docker compose up -d --dry-run     # exercises volume resolution, changes nothing
```

`--dry-run` is the important one. Confirm the three data volumes resolve to the bare names
`caddy_data` / `n8n_data` / `postgres_data`, not to project-prefixed ones. A warning that a volume
"already exists but was not created by Docker Compose" is expected and harmless — the volumes were
created by hand.

### Step 3 — cut over (15–30 seconds of downtime)

```bash
cd /srv/n8n/n8n-docker-caddy && docker compose down       # WITHOUT -v. Ever.

cd /srv/n8n
sudo mv n8n-docker-caddy      n8n-docker-caddy-old
sudo mv n8n-docker-caddy-next n8n-docker-caddy

cd n8n-docker-caddy
sudo chown 1000:1000 local_files    # n8n runs as uid 1000
make up
make ps && make logs
```

### Step 4 — verify, then clean up

```bash
curl -sSI "https://${SUBDOMAIN}.${DOMAIN_NAME}/" | head -5

# Same certificate as before, not a fresh issuance — proves caddy_data was reused
openssl s_client -connect "${SUBDOMAIN}.${DOMAIN_NAME}:443" </dev/null 2>/dev/null \
  | openssl x509 -noout -dates

git status --porcelain     # MUST be empty — this was the whole point
ls -la caddy_config/       # must contain no caddy/ subdirectory and no *.json
docker compose exec n8n printenv NODE_OPTIONS   # no stray quotes around the value
```

In the UI: log in, open a workflow, **open a credential and confirm it decrypts** (this proves the
encryption key survived), fire one test webhook.

```bash
sudo rm -rf /srv/n8n/n8n-docker-caddy-old/caddy_config/caddy   # root-owned leftovers
# keep the old checkout for a week, then remove it
```

### Rollback

Instant, because the data volumes were never touched:

```bash
cd /srv/n8n/n8n-docker-caddy && docker compose down
cd /srv/n8n
sudo mv n8n-docker-caddy     n8n-docker-caddy-next
sudo mv n8n-docker-caddy-old n8n-docker-caddy
cd n8n-docker-caddy && docker compose up -d
```

---

## What changes for a migrated host

| Before | After |
| --- | --- |
| `.env` tracked, edited in place | `.env.dist` tracked, `.env` gitignored |
| Hostname hand-edited in the Caddyfile | Derived from `{$SUBDOMAIN}.{$DOMAIN_NAME}` |
| `SSL_EMAIL` declared and unused | Wired into Caddy's ACME account |
| Caddy writing root-owned files into the repo | `/config` is a named volume, `/etc/caddy` read-only |
| `DATA_FOLDER` required, absolute | Removed; paths relative to the checkout |
| n8n on `0.0.0.0:5678` in plain HTTP | `127.0.0.1:5678` only |
| A missing variable silently becomes `""` | Compose fails with a named error |
| `docker compose …` typed by hand | `make …`, with preflight and backups |

Things to check on a migrated host:

- **Port 5678** is no longer publicly reachable. If monitoring, a script or a partner integration
  hits `host:5678`, set `N8N_HOST_PORT` in `.env`, and drop any stale firewall rule
  (`sudo ufw status`).
- **New required keys** no longer arrive with `git pull` since `.env` is not versioned. Run
  `make env-check` after every pull.

## Upgrades, afterwards

```bash
cd /srv/n8n/n8n-docker-caddy
git pull
make env-check     # any new key in .env.dist to copy over?
make upgrade       # backup -> pull -> recreate
```

`make upgrade` takes a full backup first, because n8n's database migrations are not reversible: the
only way back from a bad upgrade is restoring that backup.
