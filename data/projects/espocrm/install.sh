#!/usr/bin/env bash
# EspoCRM · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=crm.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.espocrm.com/administration/docker/installation/
#   https://docs.espocrm.com/administration/docker/caddy/
#   https://docs.espocrm.com/administration/backup-and-restore/
#   https://github.com/espocrm/espocrm-docker/blob/master/docker-entrypoint.sh
#
# Three secrets are generated here, on this machine: the password EspoCRM
# connects to MariaDB with, MariaDB's own root password, and the administrator
# password EspoCRM sets during its first start. All three go into
# /srv/espocrm/.env with mode 600 and none of them is ever printed.
#
# DOMAIN_HOST becomes ESPOCRM_SITE_URL, which EspoCRM writes into its own
# configuration on first start and builds every link it mails out of.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/espocrm}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. crm.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP, the daemon, the websocket and MariaDB want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Root keeps the application directories: the EspoCRM container chowns them to
# its web-server user on the way up, and MariaDB chowns its own to the uid it
# runs as. A directory pre-owned by the login user is how each of them fails.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/db"
sudo install -d -m 755 "$APP_DIR/data" "$APP_DIR/custom" "$APP_DIR/client-custom"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex for the two that travel inside a connection string, base64 for the one a
# human types. Read the administrator password later with
#   sudo grep ESPOCRM_ADMIN_PASSWORD /srv/espocrm/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		ESPOCRM_SITE_URL=https://${DOMAIN_HOST}
		ESPOCRM_WEB_SOCKET_URL=wss://${DOMAIN_HOST}/ws
		ESPOCRM_DATABASE_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
		ESPOCRM_ADMIN_PASSWORD=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-espocrm"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: three open, and none of 8128, 8228 or 3306 is one of them -----

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8128, 8228 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start is slow: the app container runs the installer and builds the
# schema, and the daemon and the websocket wait on its health check.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ (this takes minutes on a small box)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs --tail 40 espocrm"

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>EspoCRM</title>' \
	|| die "the page at https://${DOMAIN_HOST}/ is not EspoCRM. Check: docker compose logs --tail 40 espocrm"

# The built-in default administrator password must not work. Upstream's
# entrypoint falls back to it when the environment does not set one.
default_auth="$(curl -sS -o /dev/null -w '%{http_code}' -u admin:password "https://${DOMAIN_HOST}/api/v1/App/user" || true)"
[ "$default_auth" = "401" ] || die "the built-in default login returned ${default_auth}, not 401. Stop and investigate."

# The websocket container has started and written to the shared configuration.
ws="$(docker compose exec -T espocrm bin/command config:get useWebSocket | tr -d '[:space:]')"
[ "$ws" = "true" ] || die "useWebSocket is ${ws:-empty}. Check: docker compose logs --tail 30 espocrm-websocket"

docker compose ps

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T espocrm-db sh -c 'exec mariadb-dump -u espocrm -p"$MARIADB_PASSWORD" --single-transaction espocrm' \
	| gzip > "$APP_DIR/backups/espocrm-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/espocrm-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data custom client-custom -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/espocrm-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/espocrm-files-${STAMP}.tar.gz" ] || die "the file archive is empty"

cat <<-DONE

	EspoCRM is answering at https://${DOMAIN_HOST}/

	  1. Sign in as admin. Your password is in $APP_DIR/.env, mode 600. Read it
	     with
	       sudo grep ESPOCRM_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and it
	     is the only account this install has.
	  2. That password was applied once, during the first start. Editing .env
	     later changes nothing; change it inside the CRM instead.
	  3. Four containers are running. espocrm serves the pages, espocrm-daemon
	     runs the job queue that notification email and inbound mail need,
	     espocrm-websocket carries live notifications, espocrm-db holds every
	     record. If the daemon stops, the CRM keeps answering and quietly stops
	     doing anything on a schedule.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. They belong together, because the archive carries
	     data/config-internal.php. Both are on the same disk as the data, which
	     is not a backup. Copy them somewhere else tonight.

DONE
