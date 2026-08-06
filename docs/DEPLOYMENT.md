# Deployment and migration runbook

Three situations:

- **[Fresh host](#fresh-host)** — nothing deployed yet.
- **[Migrating an existing deployment](#migrating-an-existing-deployment)** — a server running a
  revision from before `.env` was untracked, where `git status` shows `modified: .env` and
  `modified: caddy_config/Caddyfile`. **Read this before running `git pull` there.**
- **[Migrating a legacy SQLite host](#migrating-a-legacy-sqlite-host)** — a server old enough to
  predate the Postgres commit, where n8n still stores everything in `database.sqlite`.

Two conventions apply throughout:

- **`postgres` is the deployment branch of this fork.** `main` is still upstream's pre-Postgres
  revision, so every `git clone` here carries `-b postgres`.
- **Nothing below needs `sudo`, except the two places that say so.** The migration clones from
  whatever `origin` the old checkout has, usually `git@github.com:…`; under `sudo` git resolves
  against root's `~/.ssh` and drops the agent forwarded for your login, so the clone fails with
  `Permission denied (publickey)`. Own the deployment directory with the login user instead;
  n8n runs as uid 1000, which is what `ubuntu` already is on a stock cloud image. The scripts refuse
  to run as root for exactly this reason (`--allow-root` exists for a host where `/srv` really is
  root-owned).

---

## Fresh host

```bash
sudo install -d -o "$USER" /srv/n8n      # the one legitimate sudo: creating the parent
cd /srv/n8n
git clone -b postgres https://github.com/MakeMyWeb/n8n-docker-caddy.git
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
wrong. Copy it onto the server and run it **from the old checkout, as the user that owns it**:

```bash
cd /srv/n8n/n8n-docker-caddy
bash /path/to/migrate-existing-host.sh            # no sudo — see the note at the top
```

It clones from `https://github.com/MakeMyWeb/n8n-docker-caddy.git` by default — **not** from the old
checkout's `origin`, which on a host this old is upstream's `n8n-io/n8n-docker-caddy` and carries none
of this migration. https rather than SSH, so the clone needs no key at all.

Options: `--branch <name>` (default `postgres`), `--remote <url>` to clone from somewhere else,
`--from-origin` to use the old checkout's `origin` after all, `--no-cutover` to verify and stop,
`--allow-root`.

It reads the current state, takes a full backup outside the repo, clones the new revision into
`../n8n-docker-caddy-next`, rebuilds `.env` from the old one plus `.env.dist` (dropping
`DATA_FOLDER`, pinning `COMPOSE_PROJECT_NAME` to the observed project name), runs preflight and a
`--dry-run`, then offers the directory swap and copies `local_files/` across.

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
B=/srv/n8n/backup-$(date +%F); install -d -m 700 "$B"

cp -a .env "$B/env.backup"                           # the ONLY copy of the real password
cp -a caddy_config/Caddyfile "$B/Caddyfile.backup"

docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
  > "$B/database.dump"
for v in n8n_data caddy_data; do
  docker run --rm -v "$v:/src:ro" -v "$B":/out alpine sh -c \
    "tar czf /out/$v.tgz -C /src . && chown $(id -u):$(id -g) /out/$v.tgz"
done

chmod 600 "$B"/*
ls -l "$B"
```

The `chown` inside the container matters: it runs as root, so without it the tarballs come back
root-owned and you need `sudo` to read your own backup.

`n8n_data` carries the encryption key. A database dump without it restores workflows whose
credentials can never be decrypted.

### Step 2 — new checkout alongside the current one

```bash
cd /srv/n8n
git clone -b postgres https://github.com/MakeMyWeb/n8n-docker-caddy.git n8n-docker-caddy-next
cd n8n-docker-caddy-next

cp "$B/env.backup" .env
chmod 600 .env
```

Reconcile `.env` against `.env.dist`:

- add `COMPOSE_PROJECT_NAME=` with the value from step 0
- remove `DATA_FOLDER` (obsolete: paths are now relative to the checkout)
- optionally set the `*_IMAGE_TAG` keys to the versions observed in step 0, to pin them

Then verify, without mutating anything:

```bash
make env-check
make preflight
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
mv n8n-docker-caddy      n8n-docker-caddy-old
mv n8n-docker-caddy-next n8n-docker-caddy

cd n8n-docker-caddy
cp -a ../n8n-docker-caddy-old/local_files/. local_files/   # gitignored: the clone has none
stat -c %u local_files                                     # must be 1000, n8n's uid
make up
make ps && make logs
```

Copying `local_files/` is not optional: its contents are gitignored, so the new checkout arrives with
nothing but `.gitkeep` and `/files` would be empty inside n8n. Copy, never move — the old checkout has
to stay intact for the rollback.

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
sudo rm -rf /srv/n8n/n8n-docker-caddy-old/caddy_config/caddy   # root-owned Caddy leftovers
# keep the old checkout for a week, then remove it
```

That `sudo` is unavoidable: the old compose file bind-mounted `/config` writable, so Caddy wrote those
files as root. The new one uses a named volume precisely so it cannot happen again.

### Rollback

Instant, because the data volumes were never touched:

```bash
cd /srv/n8n/n8n-docker-caddy && docker compose down
cd /srv/n8n
mv n8n-docker-caddy     n8n-docker-caddy-next
mv n8n-docker-caddy-old n8n-docker-caddy
cd n8n-docker-caddy && docker compose up -d
```

---

## Migrating a legacy SQLite host

A host still on `2f93c08` or earlier predates the Postgres commit: there is no `postgres` service, and
n8n keeps workflows, credentials, users and execution history in `database.sqlite` **inside the
`n8n_data` volume**. Everything from the section above still applies — plus the database has to be
recreated, because n8n has no SQLite-to-Postgres converter.

The route taken here is n8n's own CLI: export the workflows and credentials from the running SQLite
instance, start the new stack on an empty Postgres database, import them back.

**What survives:** workflows (ids, nodes, tags), credentials — still encrypted, and still decryptable
because `n8n_data` is `external` under the same bare name in both compose files, so the new stack
mounts *the same* `/home/node/.n8n/config`. That key file is the whole reason the credentials do not
have to be re-entered.

**What does not:** execution history, the user accounts (you create a new owner), variables, insights.
None of it is destroyed — it stays in the `database.sqlite` inside `n8n_data.tgz` in the migration
backup — but nothing imports it.

`scripts/migrate-existing-host.sh` detects this host automatically and takes the export itself:

```bash
cd /srv/docker/n8n-docker-caddy
docker compose up -d                       # the export needs n8n running
bash /path/to/migrate-existing-host.sh
```

No `--remote` needed: the default already points at the fork, which is the whole reason it is not
derived from the old checkout's `origin`.

Compared with the Postgres case it additionally:

- skips `pg_dump` (there is no database to dump) and instead runs
  `n8n export:workflow --backup` and `n8n export:credentials --backup` into
  `local_files/n8n-export-<stamp>/`, recording a SHA-256 of the encryption key next to them;
- creates the missing `postgres_data` volume, empty on purpose;
- **generates a `POSTGRES_PASSWORD`** (the old `.env` has none) and pins `N8N_IMAGE_TAG` to the version
  currently running, so the import happens on the version the export came from. Upgrade afterwards, as
  a separate step.

After the cutover the stack is up on an empty database, and two steps are left **in this order**:

```bash
# 1. https://<subdomain>.<domain>/setup   -> create the owner account
# 2.
cd /srv/docker/n8n-docker-caddy
./scripts/import-legacy-export.sh          # newest local_files/n8n-export-* by default
```

The owner account cannot be skipped and cannot be scripted: n8n attaches imported workflows and
credentials to the instance owner's personal project, and there is no CLI to create it. Reuse the same
e-mail address if you like — the old accounts lived in SQLite and are not migrated.

`import-legacy-export.sh` refuses to run if the encryption key no longer matches the fingerprint taken
at export time, if no user account exists yet, or if the database already holds workflows (`--force`
overrides the last one). Then:

- **every imported workflow arrives deactivated.** n8n's `import:workflow` deactivates on purpose
  (`--activeState=fromJson` only works in queue/multi-main mode), so nothing fires while you are still
  checking. Re-enable them by hand. Webhook URLs are unchanged: same domain, same workflow and node
  ids.
- **open one credential and confirm it shows its secret.** That single check proves the encryption key
  was reused correctly, and it is the one that matters.

### Why the import backfills `workflow_history`

The import runs on the version the export came from, and older n8n releases' `import:workflow` writes
`workflow_entity.versionId` without the matching row in `workflow_history`. Nothing notices until
something sets `workflow_entity.activeVersionId`, which is constrained by:

```
FOREIGN KEY ("activeVersionId") REFERENCES workflow_history("versionId") ON DELETE RESTRICT
```

Two things do exactly that: activating a workflow, and the
`ActivateExecuteWorkflowTriggerWorkflows` migration of a later upgrade, which activates workflows
holding an Execute Workflow Trigger or an Error Trigger. That migration runs **before** n8n serves
traffic, so the failure mode is a crash loop:

```
ERROR: insert or update on table "workflow_entity" violates foreign key constraint
DETAIL: Key (activeVersionId)=(…) is not present in table "workflow_history".
Migration "ActivateExecuteWorkflowTriggerWorkflows…" failed
n8n-1 exited with code 1 (restarting)
```

`import-legacy-export.sh` therefore inserts one history snapshot per current version, right after
importing. Recent versions create those rows themselves, so it reports `backfilled 0` and changes
nothing.

**On a host imported before this backfill existed**, repair it with the stack half-up — `n8n` stopped
so nothing writes, `postgres` running:

```bash
docker compose stop n8n
docker compose exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f -' <<'SQL'
BEGIN;
INSERT INTO workflow_history ("versionId", "workflowId", authors, nodes, connections)
SELECT w."versionId", w.id, 'legacy import backfill', w.nodes, w.connections
FROM workflow_entity w
WHERE w."versionId" IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM workflow_history h WHERE h."versionId" = w."versionId");
COMMIT;
SQL
docker compose up -d n8n && make logs S=n8n
```

The migration then completes and n8n starts. Re-running the insert is a no-op.

Rollback stays free right up to the import — the SQLite database is untouched inside `n8n_data`, so
swapping the directories back and starting the old stack returns to the previous state. Once you have
imported and started working in the new instance, going back means losing whatever you did there.

---

## Disk usage

```bash
make disk
```

Three sections: the size of each volume, a breakdown of `n8n_data`, and the ten largest tables.

`n8n_data` is `/home/node/.n8n`, and a multi-gigabyte one is usually not a leak:

| Path | What it is |
| --- | --- |
| `binaryData/` | Binary payloads of retained executions. Deleted only when the executions themselves are pruned. Normally the largest item. |
| `database.sqlite` | On a host migrated from SQLite: the old database, unused but still archived in every backup. `make disk` flags it. Deleting it is safe once you no longer want its history. |
| `nodes/node_modules/` | Community nodes installed from the UI. |
| `ssh/` | Keys generated for git-based workflows. |
| `config` | The encryption key. ~200 bytes, and the reason this volume is in every backup. |

On the database side, `execution_entity` and `execution_data` dominating is equally normal. n8n prunes
on a rolling basis already — `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=336` (14 days),
`EXECUTIONS_DATA_PRUNE_MAX_COUNT=10000` — so the size reflects that retention window, not a runaway.
`.env.dist` documents those keys, commented out at n8n's own defaults; the biggest single saving is
usually `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`, which keeps failures only.

Lowering any of them deletes the history beyond the new limit on the next prune, permanently. Take a
`make backup` first if that history has any value.

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
