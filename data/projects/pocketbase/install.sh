#!/usr/bin/env bash
# PocketBase · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=api.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://pocketbase.io/docs/
#   https://pocketbase.io/docs/going-to-production/
#   https://pocketbase.io/docs/api-health/
#   https://github.com/muchobien/pocketbase-docker/blob/22f36a08837f26b22a3327cb8066ad63c3362c70/entrypoint.sh
#   https://caddyserver.com/docs/automatic-https
#
# The PocketBase project publishes no Docker image and says so in its own
# production documentation. compose.yml pins a community build by digest; read
# the comment at the top of that file before you run this, because the trust
# decision it describes is yours, not this script's.
#
# One secret is generated here, on this machine: the password of the first
# superuser. It goes into /srv/pocketbase/.env with mode 600 and is never
# printed. ADMIN_EMAIL is a login name, not a mailbox; nothing here sends mail.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/pocketbase}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. api.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address your superuser account will be created under"
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
# The container runs as uid 1000, so its data directory belongs to 1000.
# Backups belong to the login user, who is the one copying them off the box.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: this string is retyped into a browser login form.
# Read it later with
#   sudo grep PB_ADMIN_PASSWORD /srv/pocketbase/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PB_ADMIN_EMAIL=${ADMIN_EMAIL}
		PB_ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-pocketbase"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8166 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8166 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it and prove it works ------------------------------------------
#
# The image's entrypoint runs `pocketbase superuser upsert` from the two
# variables in .env before it starts the web server, so the superuser account
# exists before the port ever answers a request.

docker compose pull
docker compose up -d

# The community image is only worth its digest if the binary inside is the one
# upstream released. Ask it.
docker compose exec -T pocketbase pocketbase --version | grep -q '0.39.10' \
	|| die "the container is not running, or the binary in it does not report 0.39.10. Check: docker compose logs --tail 40 pocketbase"

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 pocketbase"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"message":"API is healthy."' \
	|| die "/api/health answered 200 without the healthy message. Check: docker compose logs --tail 40 pocketbase"

# The collections route requires a superuser token. Upstream answers 401 to a
# request that carries none, and a 200 here would mean the API is wide open.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/collections" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated call to /api/collections returned ${unauth}, not 401. Stop and investigate."

docker compose logs pocketbase | grep -q 'Successfully saved superuser' \
	|| die "the entrypoint never created a superuser, so .env is not reaching the container. Check step 3."

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped, then copied: upstream says the application must not be running while
# pb_data is copied. The archive also carries the live Caddy site block.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/pocketbase-${STAMP}.tar.gz" -C "$APP_DIR" data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/pocketbase-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	PocketBase is answering at https://${DOMAIN_HOST}/api/health

	  1. Sign in at https://${DOMAIN_HOST}/_/ . The first screen is a form
	     headed "Superuser login". Your address is ${ADMIN_EMAIL} and your
	     password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep PB_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. That .env file stays the source of truth for the password. The image
	     re-applies it at every container start, so a password you change in
	     the dashboard is overwritten at the next restart. Change it in .env
	     and run: docker compose up -d --force-recreate
	  3. https://${DOMAIN_HOST}/ answers 404 until you mount something at
	     /pb_public. The API is at /api/ and the dashboard at /_/ .
	  4. First backup written to $APP_DIR/backups: the database, the uploaded
	     files, compose.yml, .env and the live /etc/caddy/Caddyfile. It is on
	     the same disk as the data, which is not a backup. Copy it off tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/pocketbase/

DONE
