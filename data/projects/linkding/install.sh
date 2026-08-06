#!/usr/bin/env bash
# linkding · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=links.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://linkding.link/installation/
#   https://linkding.link/options/
#   https://linkding.link/backups/
#   https://linkding.link/troubleshooting/
#
# One secret is generated here, on this machine: the password for the single
# account this install creates. It goes into /srv/linkding/.env with mode 600
# and it is never printed.
#
# DOMAIN_HOST is written twice, into the Caddy site block and into
# LD_CSRF_TRUSTED_ORIGINS. The second one is what makes the login form work
# behind a proxy that terminates TLS, so a hostname change means editing both.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/linkding}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
SUPERUSER_NAME="${SUPERUSER_NAME:-admin}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. links.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data belongs to uid 33 because the container hands its web server to
# www-data and chowns that folder to uid 33 on every start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 33 -g 33 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: Docker Compose reads this same file for variable
# interpolation, so a $ inside a value would be expanded, and a human has to
# paste this one into a login form. Read it later with
#   sudo grep LD_SUPERUSER_PASSWORD /srv/linkding/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		LD_SUPERUSER_NAME=${SUPERUSER_NAME}
		LD_SUPERUSER_PASSWORD=$(openssl rand -hex 24)
		LD_CSRF_TRUSTED_ORIGINS=https://${DOMAIN_HOST}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-linkding"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8118 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8118 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The container writes its secret key, runs the migrations, turns on SQLite WAL
# mode and creates the account named in LD_SUPERUSER_NAME, all on the way up.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 linkding"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"status": "healthy"' \
	|| die "/health answered 200 without a healthy status. Check: docker compose logs --tail 40 linkding"

# The first screen is the login form, and it is the only door in.
curl -sS "https://${DOMAIN_HOST}/login/" | grep -q 'id="main-heading">Login' \
	|| die "the login page did not render its heading. Caddy may not be reaching the container."

# Exactly one account exists, the one the .env above created. linkding ships no
# sign-up page, so this number is the whole access-control surface.
users="$(docker compose exec -T linkding python manage.py shell \
	-c "from django.contrib.auth import get_user_model; print(get_user_model().objects.count())" \
	| tr -d '\r' | tail -1)"
[ "$users" = "1" ] || die "expected 1 account, found ${users}. Check that .env existed before the first start."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T linkding python manage.py full_backup "/backups/linkding-${STAMP}.zip" >/dev/null
sudo tar -czf "$APP_DIR/backups/linkding-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/linkding-${STAMP}.zip" ] || die "the bookmark backup is empty"

cat <<-DONE

	linkding is answering at https://${DOMAIN_HOST}/

	  1. The first screen is a login form. Sign in as ${SUPERUSER_NAME} with the
	     password in $APP_DIR/.env, mode 600. Read it with
	       sudo grep LD_SUPERUSER_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, there is
	     no sign-up page, and no password-reset mail is ever sent. If you lose
	     it, the way back in is
	       cd $APP_DIR && docker compose exec linkding python manage.py changepassword ${SUPERUSER_NAME}
	  2. This is the plain image, so pages are not archived as HTML here. The
	     Wayback Machine integration exists but stays off until you turn it on
	     in your own profile settings, and so do favicons and preview images.
	  3. First backup written to $APP_DIR/backups: a zip of the bookmarks and a
	     config archive. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight.
	  4. The hostname is in two places, the Caddy site block and
	     LD_CSRF_TRUSTED_ORIGINS in .env. Change one without the other and the
	     login form starts answering 403.

DONE
