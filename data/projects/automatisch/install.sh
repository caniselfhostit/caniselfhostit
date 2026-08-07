#!/usr/bin/env bash
# Automatisch · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=flows.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://automatisch.io/docs/guide/installation
#   https://automatisch.io/docs/advanced/configuration
#   https://automatisch.io/docs/advanced/credentials
#   https://github.com/automatisch/automatisch/blob/v0.15.0/packages/backend/src/config/app.js
#
# Four secrets are generated here, on this machine: the credential encryption
# key, the webhook secret key, the app secret key and the PostgreSQL password.
# All four go into /srv/automatisch/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST is also API_URL, the hostname every webhook address this instance
# hands a third party is built from. Choose it once; flows already published
# keep pointing at the old name if you move it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/automatisch}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. flows.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; two Node processes plus PostgreSQL and Redis want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex rather than base64 for all four: one of them rides inside a database
# connection string. Upstream's warning is worth repeating here, where the
# values are made: ENCRYPTION_KEY and WEBHOOK_SECRET_KEY encrypt third-party
# credentials and verify webhook requests, and changing either stops existing
# connections and flows from working. Read them later with
#   sudo grep -E 'ENCRYPTION_KEY|WEBHOOK_SECRET_KEY' /srv/automatisch/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		API_URL=https://${DOMAIN_HOST}
		ENCRYPTION_KEY=$(openssl rand -hex 32)
		WEBHOOK_SECRET_KEY=$(openssl rand -hex 32)
		APP_SECRET_KEY=$(openssl rand -hex 32)
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-automatisch"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8171, 5432 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8171, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The main container runs the database migrations on the way up, so the first
# boot takes minutes and Caddy answers 502 through most of them. The worker
# starts alongside it and says so in its own log.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthcheck (this takes minutes on a first boot)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthcheck" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/healthcheck answered ${code:-nothing}. Check: docker compose logs --tail 40 automatisch"

curl -sS "https://${DOMAIN_HOST}/internal/api/v1/automatisch/version" | grep -q '"version":"0.15.0"' \
	|| die "the version endpoint did not report 0.15.0. Something other than the pinned image is answering."

# Nobody has registered yet: installationCompleted stays false until the first
# admin is created on the installation screen.
if curl -sS "https://${DOMAIN_HOST}/internal/api/v1/automatisch/info" | grep -q '"installationCompleted":true'; then
	die "this instance already has an owner. Stop and work out whose account it is before going further."
fi

docker compose logs --tail 20 worker | grep -q 'Workers are ready' \
	|| die "the worker never reported ready, so nothing you publish would run. Check: docker compose logs --tail 40 worker"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U automatisch -d automatisch | gzip > "$APP_DIR/backups/automatisch-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/automatisch-config-${STAMP}.tar.gz" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/automatisch-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Automatisch is answering at https://${DOMAIN_HOST}/healthcheck

	  1. Open https://${DOMAIN_HOST}/ and create the first account. The screen
	     says "Installation" and the button says "Create admin". Once that
	     account exists the endpoint behind it answers 403 to everyone, and no
	     default account was ever seeded on this box.
	     Confirm it took:
	       curl -sS https://${DOMAIN_HOST}/internal/api/v1/automatisch/info | grep -o '"installationCompleted":true'
	  2. Your encryption key is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep ENCRYPTION_KEY $APP_DIR/.env
	     and put it in your password manager. It was not printed here. Every
	     credential you connect is encrypted with it, and a database restored
	     without it comes back unreadable.
	  3. Each app you connect needs its own developer registration in that
	     company's portal, done from the Apps screen after you log in. Nothing
	     here is pre-registered, and 39 of the connectors ask for a redirect URL
	     you paste into somebody else's console.
	  4. Polling triggers run on a fifteen-minute cron without an enterprise
	     licence, so the first run of a flow you publish can be a quarter of an
	     hour away. That is the software, not a broken install.
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight, and keep the pair together.

DONE
