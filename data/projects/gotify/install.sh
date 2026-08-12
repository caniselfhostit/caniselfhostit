#!/usr/bin/env bash
# Gotify · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=gotify.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://gotify.net/docs/install
#   https://gotify.net/docs/config
#   https://gotify.net/docs/pushmsg
#
# One secret is generated here: GOTIFY_DEFAULTUSER_PASS for the seeded admin
# account. It goes into /srv/gotify/.env with mode 600 and is never printed.
# A restore without .env is a lockout, so the backup always includes it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/gotify}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_USER="${ADMIN_USER:-admin}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. gotify.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 256 ] || die "only ${avail_mb} MB of RAM available; this install wants 256 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 2 ] || die "only ${avail_gb} GB free on /srv; this install wants 2 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the admin password, on the server ---------------------------
#
# Read it later with: sudo grep GOTIFY_DEFAULTUSER_PASS /srv/gotify/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		GOTIFY_DEFAULTUSER_NAME=${ADMIN_USER}
		GOTIFY_DEFAULTUSER_PASS=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-gotify"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8206 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8206 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	case "$code" in 200|301|302|303|307|308) break ;; esac
	sleep 5
done
[ "${code:-}" = "200" ] || [ "${code:-}" = "302" ] || [ "${code:-}" = "301" ] \
	|| die "root answered ${code:-nothing}. Check: docker compose logs --tail 40 gotify"

# Unauthenticated API call must be refused.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/application" || true)"
[ "$unauth" = "401" ] || die "GET /application without auth returned ${unauth}, not 401. Stop and investigate."

# Authenticated current user.
ADMIN_PASS="$(grep -E '^GOTIFY_DEFAULTUSER_PASS=' "$APP_DIR/.env" | cut -d= -f2-)"
ADMIN_NAME="$(grep -E '^GOTIFY_DEFAULTUSER_NAME=' "$APP_DIR/.env" | cut -d= -f2-)"
me="$(curl -sS -u "${ADMIN_NAME}:${ADMIN_PASS}" "https://${DOMAIN_HOST}/current/user" || true)"
echo "$me" | grep -q '"name"' || die "authenticated /current/user failed. Check credentials in .env"

# --- 7. The first backup, before day one ends --------------------------------
#
# Includes .env: that file holds the admin password. A restore without it is a
# lockout. Also includes the live Caddyfile, not the template in this directory.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/gotify-${STAMP}.tar.gz" -C "$APP_DIR" data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/gotify-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Gotify is answering at https://${DOMAIN_HOST}/

	  1. Your username is ${ADMIN_NAME}. Read the password once with
	       sudo grep GOTIFY_DEFAULTUSER_PASS $APP_DIR/.env
	     put it in your password manager, and do not paste it anywhere else.
	     It was not printed here. The password lives only in that .env file
	     until you change it in the UI.
	  2. Create an Application in the UI, copy its token, and test with
	       curl -X POST "https://${DOMAIN_HOST}/message?token=CHANGE_ME" -F "title=test" -F "message=hello"
	  3. There is no first-party iOS app. Android has the official Gotify app;
	     iPhone users need a third-party client or another path (for example ntfy).
	  4. First backup written to $APP_DIR/backups (data, .env, compose, live
	     Caddyfile). It is on the same disk as the data, which is not a backup.
	     Copy it somewhere else tonight.

DONE
