#!/usr/bin/env bash
# Meilisearch · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=search.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.meilisearch.com/docs/guides/misc/docker
#   https://www.meilisearch.com/docs/learn/security/basic_security
#   https://www.meilisearch.com/docs/resources/self_hosting/configuration/reference
#   https://github.com/meilisearch/meilisearch/blob/v1.52.0/LICENSE
#
# One secret is generated here: MEILI_MASTER_KEY. It goes into
# /srv/meilisearch/.env with mode 600 and is never printed. There is no browser
# sign-in. Unauthenticated API calls must return 401 once the key is set.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/meilisearch}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. search.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" \
	"$APP_DIR" "$APP_DIR/backups" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Master key on the server ---------------------------------------------

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-EOF
		MEILI_MASTER_KEY=$(openssl rand -hex 32)
	EOF
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block -----------------------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-meilisearch"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Firewall -------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8203 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start and assert -----------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8203/health"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8203/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 meilisearch"

unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/indexes" || true)"
[ "$unauth" = "401" ] || die "unauthenticated /indexes returned ${unauth}, not 401. Stop and investigate."

MASTER="$(grep MEILI_MASTER_KEY "$APP_DIR/.env" | cut -d= -f2-)"
auth="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${MASTER}" "https://${DOMAIN_HOST}/indexes" || true)"
[ "$auth" = "200" ] || die "authenticated /indexes returned ${auth}, not 200"
curl -sS -H "Authorization: Bearer ${MASTER}" "https://${DOMAIN_HOST}/keys" | grep -q 'Default Search API Key' \
	|| die "/keys did not list the default search key"
unset MASTER

# --- 7. First backup ---------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/meilisearch-${STAMP}.tar.gz" \
	-C "$APP_DIR" data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/meilisearch-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Meilisearch is answering at https://${DOMAIN_HOST}

	  1. There is no browser sign-in. The API expects Authorization: Bearer keys.
	  2. Master key: sudo grep MEILI_MASTER_KEY ${APP_DIR}/.env
	     Store it offline. Never put it in a frontend.
	  3. List keys (search-scoped for browsers):
	       MASTER=\$(grep MEILI_MASTER_KEY ${APP_DIR}/.env | cut -d= -f2-)
	       curl -sS -H "Authorization: Bearer \${MASTER}" https://${DOMAIN_HOST}/keys
	  4. Unauthenticated /indexes returns 401 (asserted above).
	  5. First backup at ${APP_DIR}/backups (includes .env). Copy it off this disk.
	  6. NOT YET VERIFIED on a clean harness machine.

DONE
