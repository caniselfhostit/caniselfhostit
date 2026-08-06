#!/usr/bin/env bash
# Mattermost · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=chat.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.mattermost.com/deployment-guide/server/deploy-containers.html
#   https://github.com/mattermost/docker/blob/main/env.example
#   https://docs.mattermost.com/deployment-guide/software-hardware-requirements.html
#   https://github.com/mattermost/mattermost/blob/v11.9.0/server/build/Dockerfile
#
# One secret is generated here, on this machine: the PostgreSQL password. It
# goes into /srv/mattermost/.env with mode 600 and is never printed.
#
# This script cannot create the first Mattermost account, because only a human
# with a browser can. Until that account exists, anyone who reaches DOMAIN_HOST
# can create it and become the system administrator, so do it the minute this
# script finishes. The closing summary says so again.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/mattermost}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. chat.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
	amd64|x86_64) ;;
	*) die "this machine reports ${arch}; Mattermost publishes an amd64 image only" ;;
esac

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Mattermost plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The server image is distroless and runs as uid 2000. PostgreSQL chowns its
# own cluster directory on first start, so that one is left to root.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 2000 -g 2000 "$APP_DIR/config" "$APP_DIR/data" "$APP_DIR/plugins" "$APP_DIR/client-plugins"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: this value is pasted into a connection string, where
# + and / would need escaping. Read it later with
#   sudo grep DB_PASSWORD /srv/mattermost/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DOMAIN=${DOMAIN_HOST}
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-mattermost"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8113 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8113 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Mattermost runs its own database migrations on the way up, so the first start
# is much slower than the second.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v4/system/ping"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v4/system/ping" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/v4/system/ping answered ${code:-nothing}. Check: docker compose logs --tail 40 mattermost"

curl -sS "https://${DOMAIN_HOST}/api/v4/system/ping" | grep -q '"status":"OK"' \
	|| die "ping answered 200 without status OK. Check: docker compose logs --tail 40 mattermost"

# The server should still be reporting that it has no accounts. If it does not,
# somebody already claimed the administrator account on this hostname.
curl -sS "https://${DOMAIN_HOST}/api/v4/config/client" | grep -q '"NoAccounts":"true"' \
	|| die "this server already has an account. If that was not you, stop and investigate before using it."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U mmuser -d mattermost | gzip > "$APP_DIR/backups/mattermost-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/mattermost-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env config data -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/mattermost-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Mattermost is answering at https://${DOMAIN_HOST}/api/v4/system/ping

	  1. Open https://${DOMAIN_HOST} NOW and create your account. The screen
	     is headed "Create your account", and the first account made on this
	     server becomes the system administrator. Until you make it, anyone
	     who loads that page can. Put the account password in your password
	     manager: there is no mail here, so there is no reset link.
	  2. Then prove signups are shut. This has to answer 403:
	       curl -sS -o /dev/null -w '%{http_code}\n' -X POST \\
	         -H 'Content-Type: application/json' \\
	         -d '{"email":"signup-check@example.invalid","username":"signupcheck"}' \\
	         https://${DOMAIN_HOST}/api/v4/users
	  3. Invitations are copyable links from the Invite People dialog, because
	     this install has no SMTP. Mail is the thing to add next if you want
	     password resets to work.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. They predate your account, so take a second pair once you are
	     in. Both sit on the same disk as the data, which is not a backup: copy
	     them somewhere else tonight.

DONE
