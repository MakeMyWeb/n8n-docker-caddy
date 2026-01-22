# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository provides a Docker Compose setup for self-hosting n8n (workflow automation platform) with Caddy as a reverse proxy. The setup automatically handles HTTPS/SSL certificates via Caddy and is designed for cloud hosting on platforms like DigitalOcean or Hetzner Cloud.

## Architecture

The deployment consists of three Docker services:

1. **Caddy** (`caddy:latest`): Reverse proxy handling HTTPS termination and automatic SSL certificate management via Let's Encrypt
   - Exposes ports 80 (HTTP) and 443 (HTTPS)
   - Configuration in `caddy_config/Caddyfile`
   - Proxies requests to n8n service with `flush_interval -1` (required for n8n's streaming responses)

2. **PostgreSQL** (`postgres:16`): Database for n8n data persistence
   - Stores workflows, credentials, executions, and all n8n data
   - Not exposed externally (internal service only)
   - Includes health check to ensure n8n waits for database readiness
   - Uses external volume for database persistence

3. **n8n** (`docker.n8n.io/n8nio/n8n`): Workflow automation platform
   - Internal port 5678
   - Accessed via Caddy reverse proxy at `https://{SUBDOMAIN}.{DOMAIN_NAME}`
   - Configured to use PostgreSQL for data storage (via `DB_TYPE=postgresdb`)
   - Depends on PostgreSQL service with health check condition

## Key Configuration

All environment-specific configuration is in `.env`:
- `DATA_FOLDER`: Absolute path to where volumes are mounted (must be changed from default)
- `DOMAIN_NAME` and `SUBDOMAIN`: Determine the n8n URL (e.g., n8n.example.com)
- `GENERIC_TIMEZONE`: Timezone for n8n's Cron nodes (defaults to New York if not set)
- `SSL_EMAIL`: Email address for Let's Encrypt SSL certificate registration
- `POSTGRES_USER`: PostgreSQL database user (default: n8n)
- `POSTGRES_PASSWORD`: PostgreSQL password (**must be changed to a secure password**)
- `POSTGRES_DB`: PostgreSQL database name (default: n8n)

## Docker Volumes

The setup uses **external volumes** that must be created before running:
```bash
docker volume create caddy_data
docker volume create n8n_data
docker volume create postgres_data
```

Volume mounting:
- `caddy_data`: Caddy's persistent data (SSL certificates, etc.)
- `n8n_data`: n8n's internal data (binary data, encryption key)
- `postgres_data`: PostgreSQL database files (workflows, credentials, executions)
- `${DATA_FOLDER}/caddy_config`: Caddy configuration files
- `${DATA_FOLDER}/local_files`: Shared volume for n8n file operations (mounted at `/files` in n8n)

## Common Commands

Start services:
```bash
docker-compose up -d
```

Stop services:
```bash
docker-compose down
```

View logs:
```bash
docker-compose logs -f
docker-compose logs -f n8n
docker-compose logs -f caddy
```

Restart specific service:
```bash
docker-compose restart n8n
docker-compose restart caddy
docker-compose restart postgres
```

Access PostgreSQL database:
```bash
docker-compose exec postgres psql -U n8n -d n8n
```

Backup PostgreSQL database:
```bash
docker-compose exec postgres pg_dump -U n8n n8n > backup.sql
```

Restore PostgreSQL database:
```bash
docker-compose exec -T postgres psql -U n8n -d n8n < backup.sql
```

## Important Notes

- The `.env` file must be updated with actual values before deployment (especially `DATA_FOLDER`, `DOMAIN_NAME`, `SUBDOMAIN`, `SSL_EMAIL`, and `POSTGRES_PASSWORD`)
- **Security**: Change `POSTGRES_PASSWORD` to a strong, unique password before deployment
- Basic authentication was removed in recent commits - authentication is now handled entirely by n8n
- The Caddyfile uses a placeholder `n8n.<domain>.<suffix>` that Caddy will replace with the actual domain from environment variables
- The `flush_interval -1` setting in Caddyfile is critical for n8n's SSE (Server-Sent Events) functionality
- n8n waits for PostgreSQL to be healthy before starting (via `depends_on` with health check condition)
- All n8n data (workflows, credentials, executions) is stored in PostgreSQL, not in the n8n_data volume
