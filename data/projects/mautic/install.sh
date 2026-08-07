#!/usr/bin/env bash
# Mautic · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=mautic.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/mautic/docker-mautic
#   https://github.com/mautic/docker-mautic/blob/main/common/docker-entrypoint.sh
#   https://docs.mautic.org/en/7.1/configuration/cron_jobs.html
#   https://docs.mautic.org/en/7.1/configuration/settings.html
#
# Three secrets are generated here, on this machine: the mautic database
# password, the MariaDB root password, and the password for the one
# administrator account. All three go into /srv/mautic/.env with mode 600 and
# none of them is ever printed.
#
# DOMAIN_HOST becomes Mautic's Site URL. Every link, unsubscribe address and
# tracking pixel in every message this install sends is built from it, so
# changing it later breaks the mail people have already received.
#
# This script does not configure a mail relay. Mautic ships pointed at
# smtp://localhost:1025, which is nothing, and until you replace that under
# Settings -> Configuration -> Email Settings, no campaign leaves the box.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/mautic}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. mautic.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the administrator account should carry"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; two PHP containers plus MariaDB want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The Mautic image starts as root, checks its four mounts exist and chowns them
# to www-data, and MariaDB chowns its own data directory. Neither is chowned
# here, because a directory already claimed is how both fail on first boot.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/config" "$APP_DIR/logs" "$APP_DIR/media" "$APP_DIR/media/files" "$APP_DIR/media/images"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex for the two database credentials, base64 for the one a human types into a
# browser. Read them later with
#   sudo grep -E 'MARIADB_PASSWORD|MAUTIC_ADMIN_PASSWORD' /srv/mautic/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		MARIADB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
		MAUTIC_ADMIN_PASSWORD=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-mautic"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8161 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8161 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it, then install the schema and the one account ----------------

docker compose pull
docker compose up -d

echo "==> waiting for the mautic-web container to report healthy"
for _ in $(seq 1 40); do
	state="$(docker inspect -f '{{.State.Health.Status}}' mautic-web 2>/dev/null || echo none)"
	[ "$state" = "healthy" ] && break
	sleep 10
done
[ "${state:-}" = "healthy" ] || die "mautic-web is ${state:-missing}. Check: docker compose logs --tail 40 mautic_web"

docker compose exec -T -u www-data -w /var/www/html mautic_web \
	sh -c "php ./bin/console mautic:install https://${DOMAIN_HOST} --admin_email ${ADMIN_EMAIL} --admin_password \"\$MAUTIC_ADMIN_PASSWORD\" --force"

# Upstream calls trusted proxies mandatory behind a TLS-terminating proxy, and
# the installer never asks. Without it every tracked visit is recorded as
# arriving from the Docker bridge instead of from the visitor.
if ! docker compose exec -T mautic_web grep -q trusted_proxies /var/www/html/config/local.php; then
	docker compose exec -T -u www-data mautic_web sh -c 'cat >> /var/www/html/config/local.php' <<-'PROXIES'
		$parameters['trusted_proxies'] = ['127.0.0.1', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];
	PROXIES
fi
docker compose restart mautic_web
sleep 25

code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/s/login" || true)"
[ "$code" = "200" ] || die "https://${DOMAIN_HOST}/s/login answered ${code}. Check: docker compose logs --tail 40 mautic_web"

curl -sS "https://${DOMAIN_HOST}/s/login" | grep -q 'Username or email' \
	|| die "the login page did not contain 'Username or email'. Stop and investigate."

# The cron container is what keeps segments, campaigns and triggers moving.
docker compose exec -T mautic_cron crontab -l -u www-data | grep -q 'mautic:segments:update' \
	|| die "mautic-cron has no crontab yet. Run: docker compose restart mautic_cron"

# End to end: a console command reaching the database the web container wrote.
docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:segments:update --no-ansi >/dev/null \
	|| die "mautic:segments:update failed. Check: docker compose logs --tail 40 mautic_web"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
	| gzip > "$APP_DIR/backups/mautic-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/mautic-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env config media -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/mautic-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Mautic is answering at https://${DOMAIN_HOST}/s/login

	  1. Log in as admin. The password is in $APP_DIR/.env, mode 600. Read it
	     with
	       sudo grep MAUTIC_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Nothing can send yet. Settings -> Configuration -> Email Settings
	     ships pointed at smtp://localhost:1025 with a from-address of
	     email@yoursite.com. Replace both with your relay and an address on a
	     domain you own, and use Test connection before saving.
	  3. Settings -> Configuration -> System Settings: list every website you
	     will drop the tracking script on under CORS Valid Domains, or its
	     forms will fail quietly.
	  4. Segments, campaigns and triggers are recomputed by the mautic-cron
	     container every 15 minutes, not when you look at a page. A count that
	     has not moved yet is usually that, not a broken filter.
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. Both carry live credentials and both sit on the same disk as
	     the data, which is not a backup. Copy them off the box tonight.

DONE
