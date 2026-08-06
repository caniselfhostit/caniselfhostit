#!/usr/bin/env bash
# Ghost · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=blog.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.ghost.org/install/docker/
#   https://docs.ghost.org/config/
#   https://docs.ghost.org/faq/supported-databases/
#   https://hub.docker.com/_/ghost
#   https://hub.docker.com/_/mysql
#
# Two secrets are generated here, on this machine: the MySQL root password and
# the password for the `ghost` database user. Both go into /srv/ghost/.env with
# mode 600 and neither is ever printed.
#
# DOMAIN_HOST becomes Ghost's `url`. Every canonical link, RSS item and
# newsletter footer is built from it, so choose it once.
#
# This script stops short of creating the first account. Only a human can fill
# in the setup form at https://<DOMAIN_HOST>/ghost/, and until they do, whoever
# loads that page owns the publication. Do it the minute this script finishes.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/ghost}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. blog.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Ghost plus MySQL 8 wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# content/ and mysql/ stay owned by root. Both images start as root, chown their
# own directory to the uid they run as, and then drop privileges. One that has
# already been chowned to the login user makes MySQL refuse to initialise.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/content"
sudo install -d -m 700 "$APP_DIR/mysql"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: they travel inside connection strings and
# neither wants escaping. Read them later with
#   sudo grep -E 'MYSQL_ROOT_PASSWORD|GHOST_DB_PASSWORD' /srv/ghost/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		GHOST_URL=https://${DOMAIN_HOST}
		MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
		GHOST_DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-ghost"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8100 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8100 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MySQL spends its first half minute initialising an empty data directory, and
# Ghost then runs its whole migration set before it binds 2368. A 502 during
# that window is expected, not a fault.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ghost/api/admin/authentication/setup"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/ghost/api/admin/authentication/setup" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the setup endpoint answered ${code:-nothing}. Check: docker compose logs --tail 40 ghost"

# Upstream's setup endpoint reports status false while the site has no owner.
curl -sS "https://${DOMAIN_HOST}/ghost/api/admin/authentication/setup" | grep -q '"status":false' \
	|| die "the setup endpoint answered 200 but not status false. An account may already exist. Stop and investigate."

home_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$home_code" = "200" ] || die "https://${DOMAIN_HOST}/ returned ${home_code}, not 200"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers ghost' \
	| gzip > "$APP_DIR/backups/ghost-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/ghost-content-${STAMP}.tar.gz" content compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/ghost-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Ghost is answering at https://${DOMAIN_HOST}/ and has no owner yet.

	  1. Open https://${DOMAIN_HOST}/ghost/ now. The first screen says
	     "Welcome to Ghost." and asks for a site title, your name, an email
	     address and a password of at least 10 characters. Until you fill it
	     in, anyone who loads that page becomes the owner of this site.
	     Then confirm the door is shut:
	       curl -sS https://${DOMAIN_HOST}/ghost/api/admin/authentication/setup
	     It must print {"setup":[{"status":true}]}
	  2. The email address there is only a login. No mail is configured, so
	     member signup links, newsletters and password resets will not send
	     until you set up an SMTP provider yourself.
	  3. Two passwords are in $APP_DIR/.env, mode 600, and neither was printed
	     here. Read them with
	       sudo grep -E 'MYSQL_ROOT_PASSWORD|GHOST_DB_PASSWORD' $APP_DIR/.env
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     content archive. They are on the same disk as the data, which is not
	     a backup. Copy them somewhere else tonight.

DONE
