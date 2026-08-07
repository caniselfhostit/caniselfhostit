#!/usr/bin/env bash
# Zipline · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=share.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://zipline.diced.sh/docs/get-started/docker
#   https://zipline.diced.sh/docs/config
#   https://zipline.diced.sh/docs/config/core
#   https://zipline.diced.sh/docs/guides/hardening
#   https://zipline.diced.sh/docs/guides/reverse-proxy
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# CORE_SECRET, which signs session cookies. Both go into /srv/zipline/.env with
# mode 600 and neither is ever printed.
#
# This script stops one step short of a finished install, on purpose. Only a
# human can open a browser and claim the setup wizard, so it verifies that the
# wizard is waiting and hands you the URL.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/zipline}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. share.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Zipline plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays root-owned at 700: the PostgreSQL image chowns its own data
# directory on first start and refuses one that already belongs elsewhere.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/uploads" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: the database password travels inside a
# connection string, and upstream refuses to start on a CORE_SECRET shorter
# than 32 characters, which 32 hex bytes clears. Changing CORE_SECRET later
# logs every session out, including yours.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		CORE_SECRET=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-zipline"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8156 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8156 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Zipline runs its own database migrations on the way up, so the first start is
# the slow one.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/healthcheck"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/healthcheck" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/healthcheck answered ${code:-nothing}. Check: docker compose logs --tail 40 zipline"

curl -sS "https://${DOMAIN_HOST}/api/healthcheck" | grep -q '"pass":true' \
	|| die "/api/healthcheck answered 200 without pass true. Check: docker compose logs --tail 40 zipline"

# The setup wizard must be unclaimed and registration must be closed. Both are
# assertions with real security meaning: the first says nobody has taken the
# superadmin account before you, the second says nobody can sign themselves up.
curl -sS "https://${DOMAIN_HOST}/api/setup" | grep -q '"firstSetup":true' \
	|| die "/api/setup did not report firstSetup true. If this instance already has an account, stop and find out whose."

curl -sS "https://${DOMAIN_HOST}/api/server/public" | grep -q '"userRegistration":false' \
	|| die "public settings do not report userRegistration false. Stop and investigate before anyone finds this host."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U zipline -d zipline | gzip > "$APP_DIR/backups/zipline-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/zipline-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/zipline-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/zipline-files-${STAMP}.tar.gz" ] || die "the files archive is empty"

cat <<-DONE

	Zipline is answering at https://${DOMAIN_HOST}/api/healthcheck

	  1. Open https://${DOMAIN_HOST}/auth/setup and create the first account.
	     The heading reads "Welcome to Zipline!". Nobody else can create one:
	     registration is off, and the wizard closes the moment you use it.
	     The bare hostname shows a 404 screen because Zipline has no home
	     page. That is correct, not a broken proxy.
	  2. Still logged in, open Settings from the user menu and scroll to
	     "Generate Uploaders". Download the ShareX config on Windows, or the
	     Flameshot script on Linux and macOS. That file is what points the
	     screenshot tool you already use at this server.
	  3. Two secrets live in $APP_DIR/.env, mode 600, and neither was printed
	     here. You do not need to read them. Changing CORE_SECRET later logs
	     every session out, including yours.
	  4. First backup written to $APP_DIR/backups: a database dump and an
	     archive of the uploads plus the config. They are on the same disk as
	     the data, which is not a backup. Copy them off the box tonight, and
	     remember the archive grows with every file you upload.

DONE
