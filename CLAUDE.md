# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose setup for self-hosting n8n with Caddy as a reverse proxy (automatic HTTPS via Let's
Encrypt) and PostgreSQL for storage. Designed for cloud hosting on DigitalOcean, Hetzner and similar.

**Core design rule: no tracked file is ever edited on a server.** Everything host-specific lives in
`.env`, which is gitignored. `git status` must stay clean on a running deployment — that is the
acceptance criterion for any change here.

## Architecture

1. **Caddy** (`caddy:${CADDY_IMAGE_TAG:-latest}`) — HTTPS termination and certificate management
   - Ports 80 and 443
   - Receives `DOMAIN_NAME`, `SUBDOMAIN` and `SSL_EMAIL` as container env vars, because
     `caddy_config/Caddyfile` uses Caddy's own `{$VAR}` substitution, which Caddy expands when it
     parses the config. Compose interpolation alone would not be enough.
   - Proxies to n8n with `flush_interval -1`

2. **PostgreSQL** (`postgres:${POSTGRES_IMAGE_TAG:-16}`) — workflows, credentials, executions
   - Not published; internal to the Compose network
   - Health check gates n8n's startup via `depends_on: condition: service_healthy`

3. **n8n** (`docker.n8n.io/n8nio/n8n:${N8N_IMAGE_TAG:-latest}`)
   - Internal port 5678, published on `127.0.0.1` only (`N8N_HOST_PORT`), so public access goes
     exclusively through Caddy over HTTPS
   - `DB_TYPE=postgresdb`

## Configuration

`.env.dist` is tracked and documents every key. `.env` is gitignored and holds the real values.
There is no `.env.local` cascade: Compose reads exactly one `.env` for `${VAR}` interpolation, and
depending on `--env-file` flags would make any hand-typed `docker compose` command silently produce a
different stack.

Required (Compose fails with a named error if absent, rather than interpolating an empty string):
`DOMAIN_NAME`, `SUBDOMAIN`, `SSL_EMAIL`, `POSTGRES_PASSWORD`.

Optional: `COMPOSE_PROJECT_NAME` (pins container identity — must match an existing deployment),
`GENERIC_TIMEZONE`, `*_IMAGE_TAG`, `N8N_HOST_PORT`, `LOCAL_FILES_PATH`,
`N8N_DATA_TABLES_MAX_SIZE_BYTES`.

`DATA_FOLDER` was removed: bind paths are now relative to the checkout, which Compose resolves against
the compose file's directory.

## Common commands

The `Makefile` is the interface — run `make` for the list. Notable ones:

```bash
make init            # create external volumes + .env from .env.dist
make preflight       # validate .env, DNS, ports, Compose config, Caddyfile
make up / down       # start / stop
make logs S=n8n      # follow one service
make upgrade         # backup -> docker compose pull -> up -d
make backup          # database dump + n8n_data volume
make restore FILE=backups/<timestamp>
make psql            # psql shell
make caddy-reload    # apply a Caddyfile change with no downtime
```

The Makefile never parses `.env` (no `include .env`): a password containing `$`, `#` or a space breaks
naive dotenv parsing. Values are expanded by Compose, or inside the containers via `$$VAR`.

## Volumes

| Volume | Contents | Declaration |
| --- | --- | --- |
| `postgres_data` | Workflows, credentials, executions | `external: true` |
| `n8n_data` | **n8n's encryption key**, binary data | `external: true` |
| `caddy_data` | TLS certificates, ACME account key | `external: true` |
| `caddy_config` | Caddy's `autosave.json` — derived, disposable | project-scoped |

The three data volumes are `external` on purpose: Compose can neither create them empty by accident
(which would silently start n8n on a blank database) nor delete them on `down -v`. `make init`
creates them.

Bind mounts: `./caddy_config` at `/etc/caddy` **read-only** (the whole directory, not the single file
— a file bind mount pins an inode, so `git pull` would leave the container serving the old config),
and `${LOCAL_FILES_PATH:-./local_files}` at `/files`.

## Rules to respect when changing this repo

- **Never run `docker compose down -v`**, and never add a `make` target that does. It is the one
  command that can destroy the database.
- **A backup means database dump *plus* the `n8n_data` volume.** The encryption key lives in
  `/home/node/.n8n/config`; a database-only backup restores workflows whose credentials can never be
  decrypted again. `scripts/backup.sh` does both.
- **`flush_interval -1` in the Caddyfile is load-bearing.** n8n's editor streams execution output
  over SSE; removing it breaks the live log view. Do not add `encode gzip` either — compression
  reintroduces the buffering that setting exists to disable.
- **Never lower `N8N_IMAGE_TAG`.** n8n's database migrations are not reversible.
- **Only change Postgres' patch version.** A major bump refuses to start on an existing data
  directory.
- **Rotating `POSTGRES_PASSWORD` takes two steps.** The postgres image only applies the variable when
  initialising an empty data directory, so an existing deployment also needs
  `ALTER USER n8n WITH PASSWORD '…'`.
- **Never commit `.env`.** `scripts/preflight.sh` fails if it becomes tracked again.
- Authentication is handled entirely by n8n; basic auth was removed upstream.
- `make env-check` after every `git pull`: since `.env` is not versioned, new required keys arrive in
  `.env.dist` only.

## Migrating an existing server

A host deployed before `.env` was untracked has `.env` and `caddy_config/Caddyfile` locally modified.
`git pull` aborts there, and the reflex fix (`git checkout`/`restore`/`stash`/`reset`) destroys the
database password, which exists nowhere else. Use `scripts/migrate-existing-host.sh`, or follow
`docs/DEPLOYMENT.md` — never a plain pull.
