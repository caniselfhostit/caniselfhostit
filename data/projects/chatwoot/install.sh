#!/usr/bin/env bash
# Chatwoot · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=support.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://developers.chatwoot.com/self-hosted/deployment/docker
#   https://developers.chatwoot.com/self-hosted/configuration/environment-variables
#   https://developers.chatwoot.com/self-hosted/deployment/requirements
#
# Three secrets are generated here, on this machine: the Rails key that signs
# cookies and sessions, the PostgreSQL password and the Redis password. All
# three go into /srv/chatwoot/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST is also FRONTEND_URL, the address baked into the chat widget
# snippet you paste on your site and into every link Chatwoot sends.
#
# This script stops one step short of a usable install on purpose: only a human
# in a browser can fill in the one-time onboarding form that creates the
# administrator account. The closing summary says where.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/chatwoot}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. support.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; Rails plus Sidekiq plus PostgreSQL wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays root-owned at 700: the PostgreSQL image chowns its own data
# directory on first start and refuses one that has been chowned already.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/storage" "$APP_DIR/redis"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex for all three: upstream asks for an alphanumeric SECRET_KEY_BASE, and the
# other two ride inside connection strings and a container command line. No
# human logs in with any of them; the administrator password is chosen in a
# browser at the end.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		FRONTEND_URL=https://${DOMAIN_HOST}
		SECRET_KEY_BASE=$(openssl rand -hex 64)
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-chatwoot"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8102, 5432 and 6379 are none of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8102, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Prepare the database, then start it ----------------------------------
#
# db:chatwoot_prepare loads the schema on an empty database and migrates an
# existing one. It also seeds the flag that unlocks the onboarding screen.

docker compose pull
echo "==> loading the schema; this prints little and takes minutes"
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 rails"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"status":"woot"' \
	|| die "/health answered 200 without status woot. Check: docker compose logs --tail 40 rails"

# Chatwoot reports on its own dependencies here, which beats guessing from
# container states: both must read ok.
api="$(curl -sS "https://${DOMAIN_HOST}/api" || true)"
printf '%s' "$api" | grep -q '"queue_services":"ok"' || die "Chatwoot cannot reach Redis. Check: docker compose logs --tail 20 redis"
printf '%s' "$api" | grep -q '"data_services":"ok"' || die "Chatwoot cannot reach PostgreSQL. Check: docker compose logs --tail 20 postgres"

# Account signup must be off. Upstream's default is false, and an open endpoint
# here would let anyone on the internet create an account on this support desk.
signup="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/v1/accounts" || true)"
[ "$signup" = "404" ] || die "POST /api/v1/accounts returned ${signup}, not 404. Stop and investigate."

curl -sS "https://${DOMAIN_HOST}/installation/onboarding" | grep -q 'Howdy, Welcome to Chatwoot' \
	|| die "the onboarding screen did not render. Check: docker compose logs --tail 40 rails"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U chatwoot -d chatwoot_production | gzip > "$APP_DIR/backups/chatwoot-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/chatwoot-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/chatwoot-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Chatwoot is answering at https://${DOMAIN_HOST}/health

	  1. One step is left and only you can do it. Open
	       https://${DOMAIN_HOST}/installation/onboarding
	     and fill in the form headed "Howdy, Welcome to Chatwoot". It creates
	     the single administrator account and then refuses to run again. Put
	     that password in your password manager as you type it: this install
	     configures no mail, so there is no reset email.
	  2. Account signup is off, and this script checked it: an unauthenticated
	     POST to /api/v1/accounts answers 404.
	  3. Three secrets live in $APP_DIR/.env, mode 600, none of them printed
	     here. No human signs in with any of them. The Rails key in that file
	     is what verifies session cookies, so a database restored without it
	     signs everybody out.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive holding compose.yml, .env, storage/ and the Caddy site block.
	     They are on the same disk as the data, which is not a backup. Copy them
	     somewhere else tonight.

DONE
