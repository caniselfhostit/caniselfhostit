#!/usr/bin/env bash
# Immich · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=photos.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.immich.app/install/docker-compose
#   https://docs.immich.app/install/requirements
#   https://docs.immich.app/install/environment-variables
#   https://docs.immich.app/administration/reverse-proxy
#   https://docs.immich.app/administration/backup-and-restore
#
# One secret is generated here, on this machine: the PostgreSQL password. It
# goes into /srv/immich/.env with mode 600 and is never printed.
#
# This script stops one step short of a finished install, on purpose. Only a
# human with a browser can create the first Immich account, so the closing
# summary hands you that step and the two commands that close setup after it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/immich}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. photos.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

docker_major="$(docker version --format '{{.Server.Version}}' | cut -d. -f1)"
[ "$docker_major" -ge 25 ] || die "Docker Engine ${docker_major}.x is too old; the database health gate needs 25 or newer"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 6144 ] || die "only ${avail_mb} MB of RAM available; upstream's floor for this install is 6144 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB before any photos"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays owned by root at mode 700: the PostgreSQL image chowns its own
# data directory on first start and refuses one already chowned to somebody else.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/data" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: upstream restricts this password to A-Za-z0-9. You
# never need to read it. Immich talks to its own database and nothing else does.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		TZ=Etc/UTC
		DB_USERNAME=immich
		DB_DATABASE_NAME=immich
		IMMICH_ALLOW_SETUP=true
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-immich"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8098, 5432 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8098, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Roughly 5 GB of images, and the first database start builds its extensions,
# so this is the slow part. Twelve minutes of patience before giving up.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/server/ping"
for _ in $(seq 1 72); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/server/ping" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/server/ping answered ${code:-nothing}. Check: docker compose logs --tail 40 immich-server"

ping_body="$(curl -sS "https://${DOMAIN_HOST}/api/server/ping" || true)"
[ "$ping_body" = '{"res":"pong"}' ] || die "ping returned ${ping_body}, not {\"res\":\"pong\"}"

# The digest is the version, or it is not. Prove it rather than assuming it.
version_body="$(curl -sS "https://${DOMAIN_HOST}/api/server/version" || true)"
case "$version_body" in
	*'"major":3'*'"minor":1'*) : ;;
	*) die "server/version returned ${version_body}; expected major 3 minor 1" ;;
esac

# No account yet. This is the state the closing summary hands to the human.
config_body="$(curl -sS "https://${DOMAIN_HOST}/api/server/config" || true)"
case "$config_body" in
	*'"isInitialized":false'*) : ;;
	*'"isInitialized":true'*) echo "==> an account already exists on this server; skipping the registration notes below" ;;
	*) die "server/config returned nothing usable: ${config_body}" ;;
esac

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T database pg_dump --clean --if-exists --dbname=immich --username=immich | gzip > "$APP_DIR/backups/immich-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/immich-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/immich-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Immich is answering at https://${DOMAIN_HOST}/api/server/ping with {"res":"pong"}

	  1. Open https://${DOMAIN_HOST} in a browser now. The first screen reads
	     "Welcome to Immich" with a "Getting Started" button. Click it and fill in
	     the "Admin Registration" form. Whoever loads that page first becomes the
	     administrator of this server, so do it before you do anything else.
	  2. Then close setup permanently, so that form can never be reached again:
	       cd $APP_DIR
	       sed -i 's/^IMMICH_ALLOW_SETUP=true\$/IMMICH_ALLOW_SETUP=false/' $APP_DIR/.env
	       docker compose up -d --force-recreate immich-server
	     Confirm with: curl -sS https://${DOMAIN_HOST}/api/server/config
	     It must now contain "isInitialized":true.
	  3. Your phone gets the Immich app from its own store; the server endpoint to
	     type in is https://${DOMAIN_HOST}/api
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. The dump holds no photos, only where they are. The photos are
	     files under $APP_DIR/data. Both are on the same disk as the data, which
	     is not a backup. Copy them off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/immich/
	       rsync -a --exclude 'thumbs/' --exclude 'encoded-video/' vps:$APP_DIR/data/ ~/backups/immich/data/

DONE
