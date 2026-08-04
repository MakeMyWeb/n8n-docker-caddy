# Operational entry point for this stack. Run `make` for the target list.
#
# This Makefile deliberately never parses .env (no `include .env`): a password
# containing $, # or a space breaks naive dotenv parsing. Values are expanded by
# Compose or inside the containers instead.
#
# No target ever passes `-v` to `docker compose down`. See docs/DEPLOYMENT.md.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE ?= docker compose
DATA_VOLUMES := caddy_data n8n_data postgres_data
BACKUP_DIR := backups
# `logs` and `restart` accept a service: make logs S=n8n
S ?=

.PHONY: help init secret preflight env-check config up down restart logs ps \
        pull upgrade backup restore psql shell caddy-validate caddy-reload

help: ## Show this help
	@echo "Usage: make <target>"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Pass a service to logs/restart with S=, e.g. make logs S=n8n"

init: ## Create the external volumes and a starting .env (safe to re-run)
	@for v in $(DATA_VOLUMES); do \
		docker volume inspect "$$v" >/dev/null 2>&1 \
			&& echo "volume $$v already exists" \
			|| docker volume create "$$v"; \
	done
	@mkdir -p $(BACKUP_DIR)
	@if [ -f .env ]; then \
		echo ".env already exists, leaving it untouched"; \
	else \
		cp .env.dist .env && chmod 600 .env; \
		echo "created .env from .env.dist (mode 600)"; \
		echo; \
		echo "NEXT: edit .env — DOMAIN_NAME, SUBDOMAIN, SSL_EMAIL and"; \
		echo "      POSTGRES_PASSWORD (generate one with: make secret)"; \
		echo "THEN: make preflight && make up"; \
	fi

secret: ## Generate a strong random password
	@openssl rand -base64 36

preflight: ## Validate .env, the Compose config and the Caddyfile
	@./scripts/preflight.sh

env-check: ## Report keys that differ between .env and .env.dist
	@./scripts/preflight.sh --env-only

config: ## Show the fully interpolated Compose configuration
	@$(COMPOSE) config

up: preflight ## Start the stack (runs preflight first)
	$(COMPOSE) up -d
	@$(COMPOSE) ps

down: ## Stop and remove the containers (never touches the data volumes)
	$(COMPOSE) down

restart: ## Restart everything, or one service with S=<name>
	$(COMPOSE) restart $(S)

logs: ## Follow the logs, or one service's with S=<name>
	$(COMPOSE) logs -f --tail=200 $(S)

ps: ## Show container status
	@$(COMPOSE) ps

pull: ## Pull the images declared in .env without restarting anything
	$(COMPOSE) pull

upgrade: ## Back up, pull the latest images, recreate the containers
	@echo "This will back up, pull new images and recreate the containers."
	@echo "n8n's database migrations are NOT reversible: a downgrade afterwards"
	@echo "requires restoring the backup this step is about to take."
	@read -r -p "Continue? [y/N] " a; [ "$$a" = "y" ] || { echo "aborted"; exit 1; }
	@$(MAKE) --no-print-directory backup
	$(COMPOSE) pull
	$(COMPOSE) up -d
	@$(COMPOSE) ps
	@echo
	@echo "Running version:"
	@$(COMPOSE) exec -T n8n n8n --version || true
	@echo "Old images are kept. Remove them with: docker image prune -f"

backup: ## Dump the database AND the n8n_data volume into backups/
	@./scripts/backup.sh

restore: ## Restore a backup: make restore FILE=backups/<timestamp>
	@./scripts/restore.sh "$(FILE)"

psql: ## Open a psql shell on the database
	$(COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

shell: ## Open a shell inside the n8n container
	$(COMPOSE) exec n8n sh

caddy-validate: ## Validate the Caddyfile in a throwaway container
	docker run --rm -v "$(CURDIR)/caddy_config:/etc/caddy:ro" \
		caddy:latest caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

caddy-reload: ## Reload the Caddyfile with no downtime
	$(COMPOSE) exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
