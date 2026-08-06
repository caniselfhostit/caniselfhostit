#!/usr/bin/env bash
# Kimai · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=time.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.kimai.org/documentation/docker-compose.html
#   https://www.kimai.org/documentation/docker.html
#   https://www.kimai.org/documentation/installation.html
#   https://www.kimai.org/documentation/backups.html
#
# Four secrets are generated here, on this machine: the MySQL root password, the
# MySQL password for the kimai database user, APP_SECRET, and the password the
# container puts on the first admin account. All four go into /srv/kimai/.env
# with mode 600 and none is ever printed.
#
# DOMAIN_HOST is also TRUSTED_HOSTS, the pattern Symfony matches every incoming
# Host header against, so it has to be the name you will actually use.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/kimai}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. time.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address for the first Kimai account"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP plus MySQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mysql and var stay root-owned here. Both images chown their own data directory
# to a uid of their choosing on first start, and this script does not fight them.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mysql"
sudo install -d -m 750 "$APP_DIR/var"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex for all four: the container's start-up script splits DATABASE_URL on /, :
# and @ and url-decodes the pieces, so any of those characters, or a %, breaks
# its wait-for-database loop. Read them later with
#   sudo grep -E 'DB_PASSWORD|APP_SECRET|ADMIN_PASSWORD' /srv/kimai/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DOMAIN_NAME=${DOMAIN_HOST}
		ADMIN_EMAIL=${ADMIN_EMAIL}
		DB_ROOT_PASSWORD=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		APP_SECRET=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-kimai"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8126 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8126 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MySQL initialises its data directory, then Kimai's start-up script waits for
# it, builds the schema and creates the admin account named in ADMIN_EMAIL.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/en/login"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/en/login" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/en/login answered ${code:-nothing}. Check: docker compose logs --tail 40 kimai"

curl -sS "https://${DOMAIN_HOST}/en/login" | grep -q '<title>Kimai</title>' \
	|| die "the login page answered 200 without a Kimai title. Check: docker compose logs --tail 40 kimai"

# The account has to exist before the summary tells anyone to sign in.
docker compose exec -T kimai /opt/kimai/bin/console kimai:user:list | grep -q 'ROLE_SUPER_ADMIN' \
	|| die "no super admin account was created. Check that ADMIN_PASSWORD is set in $APP_DIR/.env"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T sqldb sh -c 'mysqldump --single-transaction --no-tablespaces -u kimai -p"$MYSQL_PASSWORD" kimai' \
	| gzip > "$APP_DIR/backups/kimai-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/kimai-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env var -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/kimai-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Kimai is answering at https://${DOMAIN_HOST}/en/login

	  1. Read the password for the admin account now:
	       sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     It was not printed here. Put it in your password manager, then sign in
	     at https://${DOMAIN_HOST} with the username admin.
	  2. Once you are signed in, close the bootstrap out. The container's
	     start-up script runs under bash -x, so it traced that password into the
	     container log on first boot and repeats it on every restart:
	       cd $APP_DIR
	       sed -i '/^ADMIN_PASS/d' $APP_DIR/.env
	       docker compose up -d --force-recreate kimai
	     Recreating the container replaces the log file that held it. Confirm
	     with: docker compose logs kimai | grep -c 'kimai:user:create'
	     That must print 0. Your password manager is then the only copy;
	     docker compose exec -it kimai /opt/kimai/bin/console kimai:user:password admin
	     sets a new one if you lose it.
	  3. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding compose.yml, .env, var and the Caddy site block. They
	     are on the same disk as the data, which is not a backup. Copy them off
	     the box tonight.

DONE
