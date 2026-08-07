#!/usr/bin/env bash
# WordPress · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=blog.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://hub.docker.com/_/wordpress
#   https://wordpress.org/about/requirements/
#   https://developer.wordpress.org/advanced-administration/wordpress/wp-config/
#   https://developer.wordpress.org/advanced-administration/security/https/
#   https://hub.docker.com/_/mysql
#
# Two secrets are generated here, on this machine: the MySQL root password and
# the wordpress database user's password. Both go into /srv/wordpress/.env with
# mode 600 and neither is ever printed. The eight WordPress authentication keys
# and salts are not generated here: the image writes a random value for each
# into wp-config.php the first time it starts.
#
# This script cannot finish the install. WordPress creates its first account in
# a browser, and until somebody does that, whoever loads the address owns the
# site. The closing summary says so; do it in the same sitting.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/wordpress}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. blog.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP plus MySQL 8.4 wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# html and mysql stay root-owned: the WordPress entrypoint chowns html to the
# www-data it runs as, and the MySQL image does the same for its data directory.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/html"
sudo install -d -m 700 "$APP_DIR/mysql"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# PHP's own default caps uploads at 2 MB, which is smaller than a photo from a
# phone. conf.d is where the image documents changing PHP's limits.
cat > "$APP_DIR/uploads.ini" <<'INIFILE'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
INIFILE
chmod 644 "$APP_DIR/uploads.ini"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64: both travel inside connection strings. Read them later
# with
#   sudo grep -E 'MYSQL_ROOT_PASSWORD|WORDPRESS_DB_PASSWORD' /srv/wordpress/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		WORDPRESS_SITE_URL=https://${DOMAIN_HOST}
		MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
		WORDPRESS_DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-wordpress"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8152 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8152 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MySQL initialises an empty data directory, then the WordPress entrypoint
# copies the whole application into html. A 502 during that window is expected.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/wp-admin/install.php"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/wp-admin/install.php" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the installer answered ${code:-nothing}. Check: docker compose logs --tail 40 wordpress"

# The page title WordPress serves while the database holds no site yet.
curl -sS "https://${DOMAIN_HOST}/wp-admin/install.php" | grep -q 'WordPress &rsaquo; Installation' \
	|| die "that address answered 200 but is not the installer. A site may already exist. Stop and investigate."

# Proof that the conf.d file above is mounted rather than quietly missing.
limit="$(docker compose exec -T wordpress php -r 'echo ini_get("upload_max_filesize");' || true)"
[ "$limit" = "64M" ] || die "PHP reports upload_max_filesize=${limit:-nothing}, not 64M. Check the uploads.ini mount."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers wordpress' \
	| gzip > "$APP_DIR/backups/wordpress-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/wordpress-site-${STAMP}.tar.gz" html compose.yml uploads.ini .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/wordpress-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	WordPress is serving its installer at https://${DOMAIN_HOST}/wp-admin/install.php
	and has no site yet.

	  1. Open that address now. WordPress asks for a language, then for a site
	     title, a username, a password and an email address. Until you fill it
	     in, anyone who loads that page becomes the administrator of this site.
	     Pick a username that is not admin. Then confirm the door is shut:
	       curl -sS https://${DOMAIN_HOST}/wp-admin/install.php | grep -c 'Already Installed'
	     It must print 1.
	  2. The email address there is only a login. No mail is configured, so
	     password resets and comment notifications stay silent until you set up
	     an SMTP provider yourself.
	  3. Two passwords are in $APP_DIR/.env, mode 600, and neither was printed
	     here. Read them with
	       sudo grep -E 'MYSQL_ROOT_PASSWORD|WORDPRESS_DB_PASSWORD' $APP_DIR/.env
	     The eight WordPress keys and salts live in html/wp-config.php, which
	     the image generated and the archive below carries.
	  4. First backup written to $APP_DIR/backups: a database dump and a site
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
