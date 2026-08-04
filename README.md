# n8n-docker-caddy

Self-hosted [n8n](https://n8n.io/) behind [Caddy](https://caddyserver.com/) (automatic HTTPS) with
PostgreSQL for storage.

Everything host-specific lives in `.env`, which is **not** versioned. No tracked file ever needs
editing on a server, so `git status` stays clean and `git pull` never conflicts.

## Prerequisites

Self-hosting n8n requires technical knowledge: setting up servers and containers, managing resources
and scaling, securing servers and applications, and configuring n8n. Mistakes can lead to data loss,
security issues and downtime. If you are not experienced at managing servers, consider
[n8n Cloud](https://n8n.io/cloud/) instead.

You need Docker with the Compose v2 plugin, a domain name, and a DNS `A` record for
`${SUBDOMAIN}.${DOMAIN_NAME}` pointing at the host — Let's Encrypt validates over HTTP, so the record
must exist and resolve before the first start.

Upstream tutorials for provisioning the host itself:
[DigitalOcean](https://docs.n8n.io/hosting/server-setups/digital-ocean/) ·
[Hetzner Cloud](https://docs.n8n.io/hosting/server-setups/hetzner/) ·
[community forums](https://community.n8n.io/).

## Install

```bash
git clone https://github.com/MakeMyWeb/n8n-docker-caddy.git
cd n8n-docker-caddy

make init          # creates the data volumes and .env from .env.dist
make secret        # generates a password to paste into POSTGRES_PASSWORD
$EDITOR .env       # DOMAIN_NAME, SUBDOMAIN, SSL_EMAIL, POSTGRES_PASSWORD

make up            # runs preflight, then starts the stack
make logs
```

`make up` refuses to start if anything is off: placeholders left in `.env`, a missing volume, ports
80/443 taken, a DNS record that does not point here, an invalid Caddyfile. Run `make preflight` on
its own to check without starting.

n8n is then served at `https://${SUBDOMAIN}.${DOMAIN_NAME}`.

**Already running an older revision of this repo on a server?** Do not `git pull` — see
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md). The commit that untracked `.env` records a deletion, and
resolving that the usual way destroys your database password.

## Commands

Run `make` for the full list.

| Command | What it does |
| --- | --- |
| `make up` / `make down` | Start / stop. `down` never removes data volumes. |
| `make logs` | Follow all logs. One service: `make logs S=n8n` |
| `make ps` | Container status |
| `make restart` | Restart all, or one: `make restart S=caddy` |
| `make upgrade` | Back up, pull the latest images, recreate the containers |
| `make backup` | Database dump **and** the `n8n_data` volume, into `backups/` |
| `make restore FILE=backups/…` | Restore a backup |
| `make psql` | psql shell on the database |
| `make shell` | Shell inside the n8n container |
| `make config` | Show the fully interpolated Compose config |
| `make preflight` | Validate `.env`, the Compose config and the Caddyfile |
| `make env-check` | Report keys that differ between `.env` and `.env.dist` |
| `make caddy-reload` | Apply a Caddyfile change with no downtime |
| `make secret` | Generate a strong random password |

## Configuration

All of it is in `.env`; `.env.dist` documents every key. Required: `DOMAIN_NAME`, `SUBDOMAIN`,
`SSL_EMAIL`, `POSTGRES_PASSWORD`. Compose fails immediately with a named error if one is missing,
rather than silently interpolating an empty string.

`caddy_config/Caddyfile` is generic: it derives its site address from `{$SUBDOMAIN}.{$DOMAIN_NAME}`
and its ACME contact from `{$SSL_EMAIL}`, all injected by Compose. There is nothing to edit in it per
host.

After a `git pull`, run `make env-check`: since `.env` is no longer versioned, new required keys
arrive in `.env.dist` only and have to be copied over by hand.

Structural per-host changes (a different port mapping, an extra service) belong in a gitignored
`docker-compose.override.yml`, which Compose merges automatically with no extra flags.

### Pinning versions

Images default to `latest`. Set `N8N_IMAGE_TAG`, `CADDY_IMAGE_TAG` and `POSTGRES_IMAGE_TAG` in `.env`
to pin them and make deploys reproducible. Two rules:

- **Never lower `N8N_IMAGE_TAG`.** n8n's database migrations are not reversible; going back requires
  restoring a backup.
- **Only ever change Postgres' patch version.** A major bump (16 → 17) refuses to start on an
  existing data directory and needs a dump/restore through a separate instance.

## Backups

```bash
make backup      # -> backups/<timestamp>/{database.dump,n8n_data.tgz,env}
```

The `n8n_data` volume is part of the backup for a reason: n8n's **encryption key** lives there. A
database dump on its own restores workflows whose credentials can never be decrypted again. Copy the
`backups/` directory off the host — a backup living only on the machine it protects is not a backup.

`make upgrade` takes a backup before pulling anything.

Test the restore path before you need it: `make restore FILE=backups/<timestamp>`.

## Data and volumes

| Volume | Contents |
| --- | --- |
| `postgres_data` | Workflows, credentials, execution history |
| `n8n_data` | n8n's encryption key and binary data |
| `caddy_data` | TLS certificates and the ACME account key |
| `<project>_caddy_config` | Caddy's `autosave.json` — derived, disposable |

The first three are declared `external`, which means Compose can neither create them empty by
accident nor delete them. `make init` creates them.

> **Never run `docker compose down -v`.** No `make` target does. On this stack it is the one command
> that can destroy the database, and the only way back is a restore.

`local_files/` on the host is mounted at `/files` inside n8n, for workflows that read or write files.
n8n runs as uid 1000, so if the checkout is root-owned: `sudo chown 1000:1000 local_files`.

## Security notes

- `.env` holds the database password. Keep it `chmod 600` (`make init` does); preflight warns
  otherwise. It is gitignored — verified by preflight, which fails if it ever becomes tracked again.
- n8n's port 5678 is published on `127.0.0.1` only, so the app is reachable from outside solely
  through Caddy over HTTPS. Override with `N8N_HOST_PORT` if you really need otherwise, and never set
  it to `0.0.0.0`.
- Authentication is handled entirely by n8n (basic auth was removed upstream).
- Rotating `POSTGRES_PASSWORD` takes two steps, because the postgres image only applies the variable
  when it initialises an empty data directory:

  ```bash
  make psql   # then: ALTER USER n8n WITH PASSWORD 'new-password';
  $EDITOR .env
  make up
  ```
