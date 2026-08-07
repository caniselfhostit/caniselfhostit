#!/usr/bin/env bash
# Seafile Community Edition · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=files.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://manual.seafile.com/13.0/setup/setup_ce_by_docker/
#   https://manual.seafile.com/13.0/config/env/
#   https://manual.seafile.com/13.0/setup/use_other_reverse_proxy/
#   https://manual.seafile.com/13.0/administration/backup_recovery/
#
# Five secrets are generated here, on this machine: the MariaDB root password,
# the seafile database password, the JWT signing key, the Redis password and the
# administrator's password. All five go into /srv/seafile/.env with mode 600 and
# none of them is ever printed.
#
# DOMAIN_HOST is also SEAFILE_SERVER_HOSTNAME. Seahub rebuilds every share link
# and every upload address out of it at each start, so choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/seafile}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. files.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the administrator account is created under"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Seafile, MariaDB and Redis want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data and mysql stay owned by root: the Seafile container runs as root and the
# MariaDB image chowns its own data directory to a uid of its choosing.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/data"
sudo install -d -m 700 "$APP_DIR/mysql"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the five secrets, on the server -----------------------------
#
# Hex rather than base64 for all five: two ride inside database connection
# strings and one is typed into a login form. Read them later with
#   sudo grep -E 'PASSWORD|JWT_PRIVATE_KEY' /srv/seafile/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SEAFILE_SERVER_HOSTNAME=${DOMAIN_HOST}
		INIT_SEAFILE_ADMIN_EMAIL=${ADMIN_EMAIL}
		TIME_ZONE=Etc/UTC
		INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
		SEAFILE_MYSQL_DB_PASSWORD=$(openssl rand -hex 32)
		JWT_PRIVATE_KEY=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
		INIT_SEAFILE_ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-seafile"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8140, 3306 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8140, 3306 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# First boot initialises MariaDB, creates the three databases, runs every
# migration and creates the one account. That takes minutes on a small server.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api2/ping/ (first boot takes several minutes)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api2/ping/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api2/ping/ answered ${code:-nothing}. Check: docker compose logs --tail 60 seafile"

curl -sS "https://${DOMAIN_HOST}/api2/ping/" | grep -q 'pong' \
	|| die "/api2/ping/ answered 200 without pong. Check: docker compose logs --tail 60 seafile"

# The API must refuse an unauthenticated call.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api2/auth/ping/" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# The running container is the pinned tag, and Seahub is generating https
# addresses rather than http ones. A wrong protocol here is the failure that
# makes uploads fail on a login page that works.
running_version="$(docker compose exec -T seafile printenv SEAFILE_VERSION | tr -d '\r')"
[ "$running_version" = "13.0.25" ] || die "the container reports version ${running_version}, not 13.0.25"
running_proto="$(docker compose exec -T seafile printenv SEAFILE_SERVER_PROTOCOL | tr -d '\r')"
[ "$running_proto" = "https" ] || die "SEAFILE_SERVER_PROTOCOL is ${running_proto}, not https. Uploads would fail."

curl -sSL "https://${DOMAIN_HOST}/accounts/login/" | grep -q 'login-panel-hd' \
	|| die "the login page did not render. Check: docker compose logs --tail 60 seafile"

# --- 7. The first backup, before day one ends --------------------------------
#
# --all-databases is deliberate: it carries the seafile MySQL user and its
# grants, without which a restore onto an empty MariaDB cannot log in.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-dump -uroot --opt --all-databases' \
	| gzip > "$APP_DIR/backups/seafile-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/seafile-files-${STAMP}.tar.gz" -C "$APP_DIR" data compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/seafile-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/seafile-files-${STAMP}.tar.gz" ] || die "the files archive is empty"

cat <<-DONE

	Seafile is answering at https://${DOMAIN_HOST}

	  1. Your administrator account is ${ADMIN_EMAIL}. Read its password with
	       sudo grep INIT_SEAFILE_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Sign in, create a library, and upload one file. That upload is the
	     check that matters: the web interface loads fine even when the file
	     server behind /seafhttp does not.
	  3. Nobody else can sign up. Upstream ships ENABLE_SIGNUP off, so the
	     account above is the only way in; add people from the admin panel.
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     files archive. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight, from your own machine:
	       scp vps:$APP_DIR/backups/* ~/backups/seafile/
	  5. Deleted files leave their blocks on disk until garbage collection
	     runs. That is a scheduled job you own now, not something this
	     install did for you.

DONE
