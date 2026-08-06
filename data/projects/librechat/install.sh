#!/usr/bin/env bash
# LibreChat · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=chat.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.librechat.ai/docs/local/docker
#   https://www.librechat.ai/docs/configuration/dotenv
#   https://www.librechat.ai/docs/remote/nginx
#
# Five secrets are generated here, on this machine: CREDS_KEY, CREDS_IV,
# JWT_SECRET, JWT_REFRESH_SECRET and MEILI_MASTER_KEY. All five go into
# /srv/librechat/.env with mode 600 and none is ever printed.
#
# No provider API key is generated or asked for. LibreChat is configured with
# `user_provided`, so each signed-in person enters their own key in the browser
# and it is stored encrypted with CREDS_KEY. That key is metered per token by
# the provider and billed to whoever owns it.
#
# This script leaves registration OPEN so you can create the first account,
# which upstream documents as the admin account. The closing summary gives you
# the two commands that shut it again. Do that today.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/librechat}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. chat.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; three containers want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Three owners on purpose: the mongo image chowns its own data directory on
# first start, Meilisearch runs as root inside its container, and the LibreChat
# image runs as its `node` user, which is uid 1000.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mongo" "$APP_DIR/meili"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/images" "$APP_DIR/uploads" "$APP_DIR/logs"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the five secrets, on the server -----------------------------
#
# CREDS_KEY is 32 bytes and CREDS_IV is 16, both written as hex, because that
# is what upstream documents; the app crashes on start-up without them. Read
# them later with
#   grep -E 'CREDS_|JWT_|MEILI_' /srv/librechat/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DOMAIN_CLIENT=https://${DOMAIN_HOST}
		DOMAIN_SERVER=https://${DOMAIN_HOST}
		ALLOW_REGISTRATION=true
		CREDS_KEY=$(openssl rand -hex 32)
		CREDS_IV=$(openssl rand -hex 16)
		JWT_SECRET=$(openssl rand -hex 32)
		JWT_REFRESH_SECRET=$(openssl rand -hex 32)
		MEILI_MASTER_KEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-librechat"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8112, 27017 or 7700 is one of them ------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8112, 27017 and 7700 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first pull downloads more than a gigabyte, and the app takes about a
# minute after that before /health answers.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 api"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q 'OK' \
	|| die "/health answered 200 without OK. Check: docker compose logs --tail 40 api"

config="$(curl -sS "https://${DOMAIN_HOST}/api/config" || true)"
printf '%s' "$config" | grep -q '"appTitle":"LibreChat"' \
	|| die "/api/config did not name LibreChat. Caddy may not be reaching the container."
printf '%s' "$config" | grep -q '"registrationEnabled":true' \
	|| die "/api/config says registration is closed, so nobody can create the first account."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mongodb mongodump --archive --gzip --db=LibreChat > "$APP_DIR/backups/librechat-db-${STAMP}.archive.gz"
sudo tar -czf "$APP_DIR/backups/librechat-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env images uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/librechat-db-${STAMP}.archive.gz" ] || die "the database dump is empty"

cat <<-DONE

	LibreChat is answering at https://${DOMAIN_HOST}

	  1. Registration is OPEN right now, on a public hostname. Go to
	     https://${DOMAIN_HOST} and create your account: upstream documents
	     that the first account registered becomes the admin account and that
	     there are no default credentials. Then close it, today:
	       sed -i 's/^ALLOW_REGISTRATION=true\$/ALLOW_REGISTRATION=false/' $APP_DIR/.env
	       cd $APP_DIR && docker compose up -d --force-recreate api
	     Confirm with: curl -sS https://${DOMAIN_HOST}/api/config
	     It should now say "registrationEnabled":false.
	  2. Nothing here sends mail, so that account is the whole recovery story.
	     Put its password in your password manager now.
	  3. This server holds no provider credential. Sign in, pick a provider from
	     the model menu, and paste your own key into the dialog LibreChat shows.
	     It is stored encrypted with CREDS_KEY, and it is metered per token and
	     billed to you by the provider, not by anything on this box.
	  4. Five secrets were generated into $APP_DIR/.env, mode 600, and none was
	     printed here. Read them yourself with
	       grep -E 'CREDS_|JWT_|MEILI_' $APP_DIR/.env
	  5. First backup written to $APP_DIR/backups: a MongoDB dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight. A dump restored without the .env it
	     was taken with comes back unreadable.

DONE
