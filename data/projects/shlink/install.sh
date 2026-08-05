#!/usr/bin/env bash
# Shlink · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=s.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://shlink.io/documentation/install-docker-image/
#   https://shlink.io/documentation/environment-variables/
#   https://shlink.io/documentation/supported-db-engines/
#   https://shlink.io/documentation/api-docs/authentication/
#
# Two secrets are generated here, on this machine: the PostgreSQL password and the
# initial API key. Both go into /srv/shlink/.env with mode 600 and neither is ever
# printed.
#
# DOMAIN_HOST is also DEFAULT_DOMAIN, the domain every short link will carry.
# Choose it once. Changing it later breaks every link you have handed out.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/shlink}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the short domain you pointed at this server, e.g. s.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; PHP plus PostgreSQL wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: the API key travels in an HTTP header and the
# database password in a connection string, and neither wants escaping. Read them
# later with
#   sudo grep -E 'DB_PASSWORD|INITIAL_API_KEY' /srv/shlink/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DEFAULT_DOMAIN=${DOMAIN_HOST}
		TIMEZONE=UTC
		DB_PASSWORD=$(openssl rand -hex 32)
		INITIAL_API_KEY=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-shlink"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8086 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8086 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Shlink runs its own database migrations on the way up, and the API key named in
# INITIAL_API_KEY is created once during that start-up.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/rest/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/rest/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/rest/health answered ${code:-nothing}. Check: docker compose logs --tail 40 shlink"

curl -sS "https://${DOMAIN_HOST}/rest/health" | grep -q '"status":"pass"' \
	|| die "/rest/health answered 200 without status pass. Check: docker compose logs --tail 40 shlink"

# The API must refuse an unauthenticated call. Upstream documents 401 for a
# missing, invalid, disabled or expired key.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/rest/v3/short-urls" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# End to end: a slug into the database and back out as a redirect.
docker compose exec -T shlink shlink short-url:create https://example.com/ --custom-slug=selfhost-check >/dev/null
redirect="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/selfhost-check" || true)"
[ "$redirect" = "302" ] || die "https://${DOMAIN_HOST}/selfhost-check returned ${redirect}, not 302"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U shlink -d shlink | gzip > "$APP_DIR/backups/shlink-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/shlink-config-${STAMP}.tar.gz" compose.yml Caddyfile .env
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/shlink-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Shlink is answering at https://${DOMAIN_HOST}/rest/health

	  1. There is no web interface, and https://${DOMAIN_HOST}/ returns 404.
	     That is correct: Shlink is a redirector, not a site. The official web
	     client is a separate application and this install does not run it.
	  2. Your API key is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep INITIAL_API_KEY $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  3. A test link, https://${DOMAIN_HOST}/selfhost-check, was created and
	     proved to redirect. Delete it whenever you like:
	       cd $APP_DIR && docker compose exec -T shlink shlink short-url:delete selfhost-check
	     New links need no API key from inside the container:
	       docker compose exec -T shlink shlink short-url:create https://example.com/
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
