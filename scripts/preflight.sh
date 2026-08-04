#!/usr/bin/env bash
#
# Checks that this host is ready to run the stack. Called by `make up`, and
# usable on its own with `make preflight`.
#
#   --env-only   only compare .env against .env.dist (this is `make env-check`)
#
# Exits non-zero on any error. Warnings do not block.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ENV_FILE=.env
DIST_FILE=.env.dist
ERRORS=0
WARNINGS=0

if [[ -t 1 ]]; then
	RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; DIM=$'\e[2m'; OFF=$'\e[0m'
else
	RED=''; YEL=''; GRN=''; DIM=''; OFF=''
fi

fail() { printf '%sFAIL%s  %s\n' "$RED" "$OFF" "$1"; ERRORS=$((ERRORS + 1)); }
warn() { printf '%sWARN%s  %s\n' "$YEL" "$OFF" "$1"; WARNINGS=$((WARNINGS + 1)); }
ok()   { printf '%s  ok%s  %s\n' "$GRN" "$OFF" "$1"; }
note() { printf '%s      %s%s\n' "$DIM" "$1" "$OFF"; }

# Reads one key from an env file without sourcing it, so a value containing
# $, # or a space cannot be executed or mangled.
env_get() {
	local key=$1 file=${2:-$ENV_FILE}
	[[ -f $file ]] || return 1
	sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "$file" | tail -n1
}

env_keys() {
	sed -n -E 's/^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=.*$/\1/p' "$1" | sort -u
}

# ---------------------------------------------------------------- .env exists

if [[ ! -f $ENV_FILE ]]; then
	fail "$ENV_FILE is missing. Run: make init"
	exit 1
fi

# ------------------------------------------------------------- key set vs dist

echo "Environment file"

missing=$(comm -23 <(env_keys "$DIST_FILE") <(env_keys "$ENV_FILE"))
extra=$(comm -13 <(env_keys "$DIST_FILE") <(env_keys "$ENV_FILE"))

# Keys commented out in .env.dist are optional, so only required ones are
# reported as missing. env_keys skips comments, so anything it finds in
# .env.dist is required by definition.
if [[ -n $missing ]]; then
	warn "keys present in $DIST_FILE but not in $ENV_FILE:"
	while read -r k; do [[ -n $k ]] && note "$k"; done <<<"$missing"
	note "a git pull no longer updates .env — add them by hand"
else
	ok "no key missing compared to $DIST_FILE"
fi

if [[ -n $extra ]]; then
	# DATA_FOLDER was removed from the project; flag it explicitly.
	while read -r k; do
		[[ -z $k ]] && continue
		if [[ $k == DATA_FOLDER ]]; then
			warn "DATA_FOLDER is obsolete and ignored; paths are now repo-relative. Remove it."
		else
			note "extra key in $ENV_FILE (not in $DIST_FILE): $k"
		fi
	done <<<"$extra"
fi

if [[ ${1:-} == --env-only ]]; then
	echo
	[[ $ERRORS -eq 0 ]] && echo "env-check finished with $WARNINGS warning(s)."
	exit $((ERRORS > 0 ? 1 : 0))
fi

# ------------------------------------------------------------ file permissions

perms=$(stat -c '%a' "$ENV_FILE")
if [[ $perms =~ ^[0-7]00$ ]]; then
	ok "$ENV_FILE permissions ($perms)"
else
	warn "$ENV_FILE is mode $perms — readable beyond its owner. Fix: chmod 600 $ENV_FILE"
fi

if git ls-files --error-unmatch "$ENV_FILE" >/dev/null 2>&1; then
	fail "$ENV_FILE is tracked by git! It holds the database password. Fix: git rm --cached $ENV_FILE"
else
	ok "$ENV_FILE is not tracked by git"
fi

# -------------------------------------------------------------- required values

echo
echo "Required values"

for key in DOMAIN_NAME SUBDOMAIN SSL_EMAIL POSTGRES_PASSWORD; do
	value=$(env_get "$key")
	if [[ -z ${value:-} ]]; then
		fail "$key is empty or absent"
	else
		ok "$key is set"
	fi
done

domain=$(env_get DOMAIN_NAME)
subdomain=$(env_get SUBDOMAIN)
ssl_email=$(env_get SSL_EMAIL)
pg_password=$(env_get POSTGRES_PASSWORD)
host="${subdomain}.${domain}"

# Placeholders straight out of .env.dist would produce a certificate for a
# domain we do not own, and an unusable ACME contact address.
case "$domain" in
	example.com|example.org|'') fail "DOMAIN_NAME is still the placeholder ($domain)" ;;
esac
case "$ssl_email" in
	*@example.com|*@example.org|'') fail "SSL_EMAIL is still the placeholder ($ssl_email)" ;;
esac
case "$pg_password" in
	*change_me*|change_me_to_a_secure_password)
		fail "POSTGRES_PASSWORD is still the placeholder. Generate one: make secret" ;;
esac
if [[ -n $pg_password && ${#pg_password} -lt 16 ]]; then
	warn "POSTGRES_PASSWORD is only ${#pg_password} characters. Generate one: make secret"
fi
if [[ $(env_get DATA_FOLDER) == *'<directory-path>'* ]]; then
	warn "DATA_FOLDER still holds the upstream placeholder — the key is obsolete, remove it"
fi

# ------------------------------------------------------------ external volumes

echo
echo "Docker resources"

if ! docker info >/dev/null 2>&1; then
	fail "cannot talk to the Docker daemon"
else
	ok "Docker daemon reachable"
	for v in caddy_data n8n_data postgres_data; do
		if docker volume inspect "$v" >/dev/null 2>&1; then
			ok "volume $v exists"
		else
			fail "volume $v is missing (declared external). Run: make init"
		fi
	done
fi

# ------------------------------------------------------------------- host ports

# Read the ports Compose actually resolved rather than assuming 80/443, so a
# docker-compose.override.yml that remaps them is taken into account.
# Only meaningful when the stack is down: otherwise its own containers hold them.
stack_up=$(docker compose ps --status running --services 2>/dev/null | grep -c . || true)
if [[ ${stack_up:-0} -gt 0 ]]; then
	note "stack already running — skipping the host port check"
elif ! command -v ss >/dev/null 2>&1; then
	note "ss not available — skipping the host port check"
else
	published=$(docker compose config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    cfg = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for name, svc in sorted(cfg.get("services", {}).items()):
    for port in svc.get("ports", []):
        if port.get("published"):
            print(name, port["published"])
' 2>/dev/null)

	if [[ -z $published ]]; then
		note "could not read the published ports — skipping the check"
	else
		while read -r svc port; do
			[[ -z $port ]] && continue
			if ss -Hltn "sport = :$port" 2>/dev/null | grep -q .; then
				fail "port $port ($svc) is already in use by another process"
			else
				ok "port $port ($svc) is free"
			fi
		done <<<"$published"
	fi
fi

# -------------------------------------------------------------------- DNS check

echo
echo "DNS"

resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
if [[ -z $resolved ]]; then
	warn "$host does not resolve — Let's Encrypt will fail until the DNS record exists"
else
	ok "$host resolves to $resolved"
	public_ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
	if [[ -z $public_ip ]]; then
		note "could not determine this host's public IP — skipping the comparison"
	elif [[ ,$resolved, == *,$public_ip,* ]]; then
		ok "the record points at this host ($public_ip)"
	else
		warn "$host resolves to $resolved but this host is $public_ip"
		note "if the DNS record points elsewhere, the ACME challenge will fail"
	fi
fi

# --------------------------------------------------------- compose and Caddyfile

echo
echo "Configuration"

if compose_err=$(docker compose config -q 2>&1); then
	ok "docker compose config is valid"
else
	fail "docker compose config rejected the configuration:"
	while read -r line; do [[ -n $line ]] && note "$line"; done <<<"$compose_err"
fi

caddy_image="caddy:$(env_get CADDY_IMAGE_TAG)"
[[ $caddy_image == "caddy:" ]] && caddy_image=caddy:latest
if caddy_err=$(docker run --rm \
		-e "SSL_EMAIL=$ssl_email" -e "SUBDOMAIN=$subdomain" -e "DOMAIN_NAME=$domain" \
		-v "$PWD/caddy_config:/etc/caddy:ro" "$caddy_image" \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
	ok "Caddyfile is valid (site address: $host)"
else
	fail "caddy validate rejected the Caddyfile:"
	while read -r line; do [[ -n $line ]] && note "$line"; done <<<"$caddy_err"
fi

# ------------------------------------------------------------------------ verdict

echo
if [[ $ERRORS -gt 0 ]]; then
	printf '%s%d error(s)%s and %d warning(s). Fix the errors before starting the stack.\n' \
		"$RED" "$ERRORS" "$OFF" "$WARNINGS"
	exit 1
fi
printf '%sPreflight passed%s with %d warning(s).\n' "$GRN" "$OFF" "$WARNINGS"
