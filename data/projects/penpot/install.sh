#!/usr/bin/env bash
# Penpot · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=design.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://help.penpot.app/technical-guide/getting-started/docker/
#   https://help.penpot.app/technical-guide/configuration/
#   https://help.penpot.app/technical-guide/getting-started/recommended-settings/
#   https://github.com/penpot/penpot/blob/2.17.0/common/src/app/common/flags.cljc
#
# Two secrets are generated here, on this machine: the 512-bit master key Penpot
# derives session and invitation keys from, and the PostgreSQL password. Both go
# into /srv/penpot/.env at mode 600 and neither is ever printed.
#
# DOMAIN_HOST becomes PENPOT_PUBLIC_URI. Penpot builds every share link,
# invitation and export URL from it, so choose it once.
#
# This script leaves registration OPEN so you can create the first account, then
# tells you the one command that closes it. Run that command today.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/penpot}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. design.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; five services want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The PostgreSQL image chowns its own data directory on first start, so that one
# stays root-owned. The backend and frontend both run as uid 1001 and share the
# assets directory, so that one is chowned to 1001 rather than to you.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 750 -o 1001 -g 1001 "$APP_DIR/assets"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: `openssl rand -base64 64` wraps onto two
# lines and an env file is read one line at a time. Read them later with
#   sudo grep -E 'PENPOT_SECRET_KEY|DB_PASSWORD' /srv/penpot/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PENPOT_PUBLIC_URI=https://${DOMAIN_HOST}
		PENPOT_FLAGS=enable-registration disable-email-verification enable-prepl-server
		PENPOT_SECRET_KEY=$(openssl rand -hex 64)
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-penpot"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$(dirname "$0")/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of the app's are among them ----------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8122, 5432, 6379, 6060, 6061 and 6063 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# About 1.4 GB of images, most of it the exporter's headless Chromium. The
# backend then runs its own database migrations before it answers anything.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/readyz"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/readyz" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/readyz answered ${code:-nothing}. Check: docker compose logs --tail 40 penpot-backend"

# /readyz runs a real query against PostgreSQL, so OK means both are up.
curl -sS "https://${DOMAIN_HOST}/readyz" | grep -c 'OK' >/dev/null \
	|| die "/readyz answered 200 without OK. Check: docker compose logs --tail 40 penpot-backend"

curl -sS "https://${DOMAIN_HOST}/" | grep -c 'Penpot | Full-stack design' >/dev/null \
	|| die "the page at https://${DOMAIN_HOST}/ is not Penpot's. Check: docker compose logs --tail 40 penpot-frontend"

# The browser reads what this install allows from this file.
curl -sS "https://${DOMAIN_HOST}/js/config.js" | grep -c 'enable-registration' >/dev/null \
	|| die "config.js does not carry the flags from .env. Check: docker compose logs --tail 40 penpot-frontend"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T penpot-postgres pg_dump -U penpot -d penpot | gzip > "$APP_DIR/backups/penpot-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/penpot-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env assets -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/penpot-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Penpot is answering at https://${DOMAIN_HOST}

	  1. Open it. The first screen reads "Log into my account" with a
	     "Create an account" link. Register now: registration is open, and
	     step 2 closes it.
	  2. Then close registration, from $APP_DIR:
	       sed -i 's/^PENPOT_FLAGS=enable-registration/PENPOT_FLAGS=disable-registration/' .env
	       docker compose up -d --force-recreate penpot-backend penpot-frontend
	     Reload the page in a private window: the "Create an account" link
	     must be gone. After that, people arrive by team invitation.
	  3. There is no SMTP server here, so there is no password-reset email.
	     Put your password in a manager. If it is ever lost, the way back is
	       docker compose exec -it penpot-backend python3 manage.py update-profile
	     which prompts for the new password without printing it.
	  4. Your master key and database password are in $APP_DIR/.env, mode 600.
	     Neither was printed here.
	  5. First backup written to $APP_DIR/backups: a database dump and a
	     config archive holding .env and the uploaded assets. They are one
	     backup in two files, and both are on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight.

DONE
