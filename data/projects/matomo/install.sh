#!/usr/bin/env bash
# Matomo · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=stats.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/matomo-org/docker
#   https://matomo.org/faq/how-to-install/install-matomo-with-docker/
#   https://matomo.org/faq/how-to-install/faq_98/
#   https://matomo.org/faq/on-premise/what-is-the-trusted-host-check-feature-in-matomo/
#   https://matomo.org/faq/on-premise/how-to-set-up-auto-archiving-of-your-reports/
#
# Two secrets are generated here, on this machine: the password for the matomo
# database user and the MariaDB root password. Both go into /srv/matomo/.env
# with mode 600 and neither is ever printed. Matomo itself ships no account:
# the browser wizard creates the superuser, which is why this script stops
# short of a finished install and hands you the last two steps.
#
# DOMAIN_HOST is also Matomo's trusted host and the address inside the tracking
# snippet on every page you measure. Changing it later means editing all of them.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/matomo}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. stats.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP and MariaDB want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# matomo and mariadb stay owned by root: the Matomo image unpacks its PHP tree
# into matomo and chowns it to www-data, and MariaDB chowns its data directory.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/matomo"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64: both travel inside a connection string that the
# wizard fills in for you. Read them later, if you ever need to, with
#   sudo grep -E 'MARIADB_PASSWORD|MARIADB_ROOT_PASSWORD' /srv/matomo/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		MARIADB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-matomo"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8119 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8119 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start unpacks about 200 MB of PHP into $APP_DIR/matomo, so the wait
# loop below is generous on purpose.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/index.php"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/index.php" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/index.php answered ${code:-nothing}. Check: docker compose logs --tail 40 app"

curl -sS "https://${DOMAIN_HOST}/" | grep -q 'Matomo is libre software used to analyze traffic from your visitors' \
	|| die "that hostname answered 200 without the installer welcome page. Check: docker compose logs --tail 40 app"

# --- 7. The settings the wizard never asks about -----------------------------
#
# Matomo reads config/common.config.ini.php before config/config.ini.php, so
# the wizard cannot overwrite any of this. trusted_hosts is armed before the
# wizard runs rather than after, so the installer itself is covered too.

sed "s|<DOMAIN>|${DOMAIN_HOST}|g" <<-'INI' | docker compose exec -T -u www-data app sh -c 'cat > /var/www/html/config/common.config.ini.php'
	[General]
	; Caddy terminates TLS and speaks plain http to the container, so Matomo is
	; told the request arrived over https before it builds any https link.
	assume_secure_protocol = 1
	force_ssl = 1
	proxy_client_headers[] = HTTP_X_FORWARDED_FOR
	; The only hostname allowed in a Host header.
	trusted_hosts[] = "<DOMAIN>"
	; Reports come from the archive container, not from a page load.
	enable_browser_archiving_triggering = 0
	browser_archiving_disabled_enforce = 1
INI

after="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/index.php" || true)"
[ "$after" = "200" ] || die "after writing common.config.ini.php the site answered ${after}. Read it back with: docker compose exec -T app cat /var/www/html/config/common.config.ini.php"

# --- 8. The first backup, before day one ends --------------------------------
#
# Taken now, with an empty Matomo, so the restore path is proved before there
# is anything to lose. The config archive carries the live Caddy site block,
# not the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/matomo-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/matomo-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env matomo/config -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/matomo-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/matomo-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Matomo is serving its installer at https://${DOMAIN_HOST}

	  1. Open https://${DOMAIN_HOST} in a browser now and work through the wizard.
	     The database screen is already filled in and its password masked, so keep
	     the adapter on its default and press Next. The superuser you create is the
	     only account this install has: put it
	     in your password manager before you click past that screen. The website you
	     name on the last screen owns the tracking snippet Matomo prints at the end.
	  2. Then prove the wizard is closed, which is the security check this script
	     cannot run for you:
	       curl -sS 'https://${DOMAIN_HOST}/index.php?module=Installation&action=welcome'
	     It must contain "Matomo is already installed". If it still shows the wizard,
	     an open setup form is sitting on a public hostname. Then confirm the
	     trusted-host list, which is what stops host-header injection:
	       cd $APP_DIR && docker compose exec -T -u www-data app php /var/www/html/console config:get --section=General --key=trusted_hosts
	  3. Prove tracking works end to end:
	       curl -sS -o /dev/null -w '%{http_code}\n' 'https://${DOMAIN_HOST}/matomo.php?idsite=1&rec=1&url=https%3A%2F%2Fexample.com%2F'
	       cd $APP_DIR && docker compose exec -T db sh -c 'exec mariadb -N -B -u"\$MARIADB_USER" -p"\$MARIADB_PASSWORD" -e "select count(*) from matomo_log_visit" "\$MARIADB_DATABASE"'
	     A 200 and a count of 1 or more means a tracking request became a row.
	  4. Reports are computed by the matomo-archive container, hourly, and never on
	     a page load. The dashboard is therefore empty until the first pass runs, up
	     to an hour after you finish the wizard. To see numbers sooner, run
	       docker compose exec -T -u www-data app php /var/www/html/console core:archive --no-ansi
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/matomo/

DONE
