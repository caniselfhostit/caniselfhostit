#!/usr/bin/env bash
# PrestaShop · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=shop.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://devdocs.prestashop-project.org/9/basics/installation/environments/docker/
#   https://github.com/PrestaShop/docker/blob/master/base/config_files/docker_run.sh
#   https://devdocs.prestashop-project.org/9/basics/installation/system-requirements/
#   https://hub.docker.com/_/mariadb
#
# Four values are generated here, on this machine: the database password, the
# MariaDB root password, the administrator's password, and the name of the
# back-office directory. All four go into /srv/prestashop/.env with mode 600 and
# none of them is ever printed.
#
# DOMAIN_HOST becomes PS_DOMAIN, which the installer writes into PrestaShop's own
# shop-url table. Choose it once: moving the shop later is a database edit.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/prestashop}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. shop.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the one back-office account will sign in with"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP plus MariaDB wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four values, on the server ------------------------------
#
# Hex for the two database values, base64 for the administrator's, and a short
# random suffix for the back-office directory: the image renames admin/ to that
# name before it installs, and a fixed name would be the same on every shop that
# ever ran this script. Read them later with
#   sudo grep -E 'PS_FOLDER_ADMIN|ADMIN_PASSWORD' /srv/prestashop/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PS_DOMAIN=${DOMAIN_HOST}
		ADMIN_EMAIL=${ADMIN_EMAIL}
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -base64 24)
		PS_FOLDER_ADMIN=admin-$(openssl rand -hex 4)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-prestashop"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8138 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8138 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# On the first start the image's entrypoint waits for MariaDB, renames the
# back-office directory, runs PrestaShop's console installer, then deletes the
# install directory itself. Apache does not answer until that finishes, which
# takes several minutes on a small box.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ (the console installer runs first)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the storefront answered ${code:-nothing}. Check: docker compose logs --tail 80 app"

docker compose logs app | grep -q -- '-- Installation successful! --' \
	|| die "the console installer never printed its success line. Check: docker compose logs --tail 80 app"

# The two hardening asserts. An install directory left in place is a second
# setup wizard on a public address; a back office on the default path is the
# first thing anybody scans for.
docker compose exec -T app sh -c '[ ! -d /var/www/html/install ]' \
	|| die "/var/www/html/install still exists. Take the stack down with 'docker compose down' before debugging."
docker compose exec -T app sh -c '[ ! -d /var/www/html/admin ]' \
	|| die "/var/www/html/admin still exists, so the back office is on its default path. Check PS_FOLDER_ADMIN in .env."
docker compose exec -T app test -f /var/www/html/app/config/parameters.php \
	|| die "app/config/parameters.php is missing, so PrestaShop never wrote its settings file."

ADMIN_DIR="$(grep -m1 '^PS_FOLDER_ADMIN=' "$APP_DIR/.env" | cut -d= -f2)"
admin_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/${ADMIN_DIR}/" || true)"
[ "$admin_code" = "200" ] || die "the back-office login page returned ${admin_code}, not 200"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/prestashop-db-${STAMP}.sql.gz"
docker compose exec -T app tar -C /var/www/html -czf - app/config/parameters.php img modules themes translations upload download > "$APP_DIR/backups/prestashop-shop-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/prestashop-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/prestashop-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/prestashop-shop-${STAMP}.tar.gz" ] || die "the shop archive is empty"

cat <<-DONE

	PrestaShop 9.1.4 is answering at https://${DOMAIN_HOST}/

	  1. Your back office is at https://${DOMAIN_HOST}/ plus a directory name
	     this script generated. Read it, and the administrator's password,
	     with
	       sudo grep -E 'PS_FOLDER_ADMIN|ADMIN_PASSWORD' $APP_DIR/.env
	     and put both in your password manager. Neither was printed here.
	     Sign in with ${ADMIN_EMAIL}.
	  2. The install directory is deleted and the back office is off its
	     default path. Both were checked, not assumed.
	  3. The shop opens with upstream's demo catalogue in it: t-shirts, mugs
	     and a few demo customers. That is the fixtures dataset, not a fault.
	     Delete them from Catalog in the back office.
	  4. No mail is configured, so no order confirmation reaches a customer
	     and no password reset reaches you. That is a separate build.
	  5. First backup written to $APP_DIR/backups: a database dump, a shop
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight.

DONE
