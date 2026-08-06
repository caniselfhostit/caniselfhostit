#!/usr/bin/env bash
# Nextcloud · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=cloud.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/nextcloud/docker
#   https://docs.nextcloud.com/server/34/admin_manual/installation/system_requirements.html
#   https://docs.nextcloud.com/server/34/admin_manual/configuration_server/reverse_proxy_configuration.html
#   https://docs.nextcloud.com/server/34/admin_manual/configuration_server/background_jobs_configuration.html
#
# Three secrets are generated here, on this machine: the database password for
# the nextcloud user, the MariaDB root password, and the password of the first
# administrator account. All three go into /srv/nextcloud/.env with mode 600 and
# none of them is ever printed.
#
# DOMAIN_HOST is also NEXTCLOUD_TRUSTED_DOMAINS, which Nextcloud reads once,
# during the first install. Changing the hostname later is an occ command.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/nextcloud}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. cloud.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP, MariaDB and Redis want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# html and mariadb stay owned by root: the Nextcloud image copies its own tree
# into html and chowns it to www-data, and MariaDB chowns its data directory.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/html"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64 for all three: two travel inside a connection string
# and the third gets typed into a login form. Read the admin password later with
#   sudo grep NEXTCLOUD_ADMIN_PASSWORD /srv/nextcloud/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXTCLOUD_TRUSTED_DOMAINS=${DOMAIN_HOST}
		OVERWRITECLIURL=https://${DOMAIN_HOST}
		NEXTCLOUD_ADMIN_USER=admin
		NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -hex 24)
		MYSQL_PASSWORD=$(openssl rand -hex 32)
		MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-nextcloud"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8099, 3306 or 6379 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8099, 3306 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start unpacks about 600 MB of PHP into html, waits for MariaDB, and
# then runs occ maintenance:install, because step 3 wrote an admin user and
# password before this launch. Several minutes of 502 are normal.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/status.php"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/status.php" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/status.php answered ${code:-nothing}. Check: docker compose logs --tail 40 app"

status="$(curl -sS "https://${DOMAIN_HOST}/status.php" || true)"
case "$status" in
	*'"installed":true'*) ;;
	*) die "status.php does not report installed:true. Check: docker compose logs --tail 40 app" ;;
esac
case "$status" in
	*'"versionstring":"34.0.2"'*) ;;
	*) die "status.php reports a version this script did not install: ${status}" ;;
esac

# The setup wizard must be gone: a visitor has to land on the login page, not on
# a form that would hand them the administrator account.
curl -sSL -o /tmp/nc-first-screen.html "https://${DOMAIN_HOST}/" || true
grep -q 'id="body-login"' /tmp/nc-first-screen.html \
	|| die "https://${DOMAIN_HOST}/ is not the login page. Stop and investigate before anyone else finds it."
rm -f /tmp/nc-first-screen.html

# Redis is carrying the file locks, not sitting there idle.
locking="$(docker compose exec -u www-data -T app php /var/www/html/occ config:system:get memcache.locking | tr -d '\r\n')"
[ "$locking" = '\OC\Memcache\Redis' ] || die "memcache.locking is '${locking}', not the Redis provider"

# The scheduler path works.
docker compose exec -u www-data -T app php -f /var/www/html/cron.php >/dev/null \
	|| die "cron.php failed. Background jobs will not run."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --on >/dev/null
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' \
	| gzip > "$APP_DIR/backups/nextcloud-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR/html" -czf "$APP_DIR/backups/nextcloud-files-${STAMP}.tar.gz" config data
sudo tar -czf "$APP_DIR/backups/nextcloud-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --off >/dev/null
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/nextcloud-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/nextcloud-files-${STAMP}.tar.gz" ] || die "the files archive is empty"

cat <<-DONE

	Nextcloud is answering at https://${DOMAIN_HOST}

	  1. Sign in as admin. Your password is in $APP_DIR/.env, mode 600:
	       sudo grep NEXTCLOUD_ADMIN_PASSWORD $APP_DIR/.env
	     Put it in your password manager. It was not printed here, and the
	     account name cannot be changed later.
	  2. The setup wizard is already closed: this script asserted that
	     https://${DOMAIN_HOST}/ serves the login page and that status.php
	     reports installed:true.
	  3. Four containers are running: the site, the scheduler that runs
	     cron.php every five minutes, MariaDB and Redis. Redis is holding the
	     file locks, which this script checked rather than assumed.
	  4. First backup written to $APP_DIR/backups: a database dump, a files
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/nextcloud/

DONE
