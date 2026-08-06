#!/usr/bin/env bash
# FitTrackee · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=fit.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.fittrackee.org/en/installation/index.html
#   https://docs.fittrackee.org/en/installation/installation.html
#   https://docs.fittrackee.org/en/installation/environments_variables.html
#   https://docs.fittrackee.org/en/installation/emails.html
#   https://docs.fittrackee.org/en/api/health_check.html
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# APP_SECRET_KEY. Both go into /srv/fittrackee/.env with mode 600 and neither is
# ever printed.
#
# This install is amd64 only. PostGIS is a mandatory prerequisite and upstream
# states there is no official PostGIS image for ARM platforms.
#
# The script stops after setting the active-users limit to one. Creating the
# first account is a browser step only a human can do, and activating it needs
# that account to exist first; the closing summary says which two commands
# finish the job.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/fittrackee}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. fit.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this server is ${arch}; PostGIS publishes no ARM image, so this install stops here"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Python plus PostGIS wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image runs as uid 1000, and upstream requires the uploads and static-map
# directories writable by that user. /srv/fittrackee/postgres stays root-owned
# because the database image chowns its own data directory on first start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 -o 1000 -g 1000 "$APP_DIR/uploads" "$APP_DIR/staticmap_cache"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64: the database password travels inside a connection
# string. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|APP_SECRET_KEY' /srv/fittrackee/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		UI_URL=https://${DOMAIN_HOST}
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		APP_SECRET_KEY=$(openssl rand -hex 48)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-fittrackee"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8129 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8129 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The entrypoint runs `ftcli db upgrade` before gunicorn, so the first start is
# slower than any later one.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/ping"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/ping" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/ping answered ${code:-nothing}. Check: docker compose logs --tail 40 fittrackee"

curl -sS "https://${DOMAIN_HOST}/api/check-db" | grep -q '"db available"' \
	|| die "/api/check-db did not report the database available. Check: docker compose logs --tail 20 fittrackee-db"

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>FitTrackee</title>' \
	|| die "the root URL did not serve the FitTrackee page. Check that Caddy is reaching 127.0.0.1:8129"

# --- 7. Close the door before anyone can walk through it ---------------------
#
# Upstream ships max_users at 0, which means no limit, so registration is open.
# Setting it to 1 lets exactly one account be created and closes the form the
# moment it exists. There is no environment variable and no CLI for this
# setting, and the API needs an administrator who does not exist yet.

docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -c "UPDATE app_config SET max_users = 1;" >/dev/null
docker compose restart fittrackee
sleep 20
curl -sS "https://${DOMAIN_HOST}/api/config" | grep -q '"max_users": *1[,}]' \
	|| die "the active-users limit did not take. Stop: registration is still open on a public hostname."

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T fittrackee-db pg_dump -U fittrackee -d fittrackee | gzip > "$APP_DIR/backups/fittrackee-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/fittrackee-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/fittrackee-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	FitTrackee is answering at https://${DOMAIN_HOST}

	  1. Create your account now, in a browser, at
	       https://${DOMAIN_HOST}/register
	     It will tell you to check your email. No email is coming: this
	     install sends no mail on purpose, and every new account starts
	     inactive. Then run these two lines to activate it and make it the
	     owner:
	       cd $APP_DIR
	       docker compose exec -T fittrackee ftcli users update "\$(docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -tAc 'SELECT username FROM users ORDER BY id LIMIT 1')" --set-role owner
	  2. Then confirm the door is shut:
	       curl -sS https://${DOMAIN_HOST}/api/config
	     "is_registration_enabled" must read false. One account against a
	     limit of one closes the registration form. If it reads true, stop
	     and find out why before you upload anything.
	  3. Your secrets are in $APP_DIR/.env, mode 600. Read them with
	       sudo grep -E 'POSTGRES_PASSWORD|APP_SECRET_KEY' $APP_DIR/.env
	     Neither was printed here. Your login password is the one you type
	     into the browser and is not in that file.
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     config archive holding compose.yml, .env, uploads and the Caddy
	     config. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight, and copy both: the tracks
	     are in uploads and everything computed from them is in the database.

DONE
