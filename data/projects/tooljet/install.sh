#!/usr/bin/env bash
# ToolJet · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=tools.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.tooljet.ai/docs/setup/docker/
#   https://docs.tooljet.ai/docs/setup/env-vars/
#   https://docs.tooljet.ai/docs/setup/system-requirements/
#   https://docs.tooljet.ai/docs/tooljet-db/tooljet-database/
#
# Four secrets are generated here, on this machine: the lockbox master key, the
# application secret key, the PostgreSQL password and the PostgREST JWT secret.
# All four go into /srv/tooljet/.env with mode 600 and none is ever printed.
# LOCKBOX_MASTER_KEY is the one that matters at 2am: it encrypts every
# datasource credential, so a database restored without it comes back with
# every app intact and nothing able to connect.
#
# DOMAIN_HOST is also TOOLJET_HOST, the address the server compares request
# origins against. Choose it once.
#
# This script stops one step short of a usable install on purpose: only a human
# in a browser can fill in the one-time form that creates the administrator
# account. The closing summary says where.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/tooljet}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. tools.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this machine reports ${arch}; ToolJet publishes its community-edition image for amd64 only"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; the server plus PostgreSQL wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays root-owned at 700: the PostgreSQL image chowns its own data
# directory on first start and refuses one that has been chowned already.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex at the lengths upstream documents for each. Read the lockbox key later
# with
#   sudo grep LOCKBOX_MASTER_KEY /srv/tooljet/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		TOOLJET_HOST=https://${DOMAIN_HOST}
		LOCKBOX_MASTER_KEY=$(openssl rand -hex 32)
		SECRET_KEY_BASE=$(openssl rand -hex 64)
		PG_PASS=$(openssl rand -hex 32)
		PGRST_JWT_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-tooljet"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8176, 5432 and 3000 are none of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8176, 5432 and 3000 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot pulls about 3 GB, waits for PostgreSQL, creates three
# databases and runs the migrations before anything answers. PostgREST restarts
# in a loop until the tooljet_db database and its postgrest.pre_config function
# exist; that loop ends on its own.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 60 tooljet"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"works":"yeah"' \
	|| die "/api/health answered 200 without the expected body. Check: docker compose logs --tail 60 tooljet"

# Open signup must be refused before any account exists. DISABLE_SIGNUPS is set
# in compose.yml and the guard on this endpoint reads it on every request.
signup="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/onboarding/signup" || true)"
[ "$signup" = "403" ] || die "POST /api/onboarding/signup returned ${signup}, not 403. Stop and investigate."

# The ToolJet Database is wired up once the migrations have made the function
# PostgREST needs.
echo "==> waiting for the ToolJet Database to finish setting itself up"
for _ in $(seq 1 20); do
	fn="$(docker compose exec -T postgres psql -U tooljet -d tooljet_db -tAc "select count(*) from pg_proc where proname='pre_config'" 2>/dev/null | tr -dc '0-9' || true)"
	[ "${fn:-0}" = "1" ] && break
	sleep 15
done
[ "${fn:-0}" = "1" ] || die "postgrest.pre_config was never created. Check: docker compose logs --tail 40 tooljet"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dumpall -U tooljet | gzip > "$APP_DIR/backups/tooljet-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/tooljet-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/tooljet-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	ToolJet is answering at https://${DOMAIN_HOST}/api/health

	  1. One step is left and only you can do it. Open
	       https://${DOMAIN_HOST}
	     and fill in the form headed "Set up your admin account". It makes the
	     only administrator this install has and then refuses to run again.
	     Put that password in your password manager as you type it: this
	     install configures no mail, so there is no reset email.
	  2. Open signup is off, and this script checked it: an unauthenticated
	     POST to /api/onboarding/signup answers 403.
	  3. Four secrets live in $APP_DIR/.env, mode 600, none printed here. The
	     one to keep is the lockbox key, readable with
	       sudo grep LOCKBOX_MASTER_KEY $APP_DIR/.env
	     It decrypts every datasource credential you save.
	  4. The health endpoint reports the licence as invalid and expired. That
	     is the community edition answering honestly; nothing here needs a key.
	  5. First backup written to $APP_DIR/backups: a pg_dumpall of all three
	     databases and a config archive holding compose.yml, .env and the Caddy
	     site block. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight.

DONE
