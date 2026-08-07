#!/usr/bin/env bash
# Zammad · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=help.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.zammad.org/en/latest/install/docker-compose.html
#   https://docs.zammad.org/en/latest/install/docker-compose/docker-compose-scenarios.html
#   https://docs.zammad.org/en/latest/appendix/environment-variables.html
#   https://docs.zammad.org/en/latest/prerequisites/software.html
#
# One secret is generated here, on this machine: the PostgreSQL password, which
# upstream otherwise ships as the word zammad. It goes into /srv/zammad/.env
# with mode 600 and is never printed.
#
# DOMAIN_HOST is also ZAMMAD_FQDN, the address Zammad writes into every link it
# builds.
#
# This script stops one step short of a usable install on purpose: only a human
# in a browser can work through the setup wizard that creates the administrator
# account. The closing summary says where, and what to run afterwards.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/zammad}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. help.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 6144 ] || die "only ${avail_mb} MB of RAM available; four Rails processes plus PostgreSQL want 6144 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# storage belongs to uid 1000 because that is the user the Zammad image runs as.
# postgres stays root-owned at 700: the PostgreSQL image chowns its own data
# directory on first start and refuses one that has been chowned already.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/redis"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/storage"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: it travels inside a connection string. Read it later
# with
#   sudo grep POSTGRESQL_PASS /srv/zammad/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		ZAMMAD_FQDN=${DOMAIN_HOST}
		ZAMMAD_HTTP_TYPE=https
		POSTGRESQL_PASS=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-zammad"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8169, 5432, 6379 and 11211 are none of them -----

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8169, 5432, 6379 and 11211 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Migrate, then start --------------------------------------------------
#
# The init command creates the database, loads the schema, seeds it and writes
# the FQDN from .env into the settings table. It runs once here and again after
# every image update. The other containers wait for it, so skipping it looks
# exactly like a hung boot.

docker compose pull
echo "==> loading the schema; this prints a lot and takes minutes"
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "the site answered ${code:-nothing}. Check: docker compose logs --tail 40 zammad-railsserver"

# The API must refuse a call with no session. A helpdesk on the public internet
# that answers this one with data is an incident, not an install.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/users" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated call to /api/v1/users returned ${unauth}, not 401. Stop and investigate."

setup="$(curl -sS -H 'Content-Type: application/json' -d '{"query":"{systemSetupInfo{status}}"}' "https://${DOMAIN_HOST}/graphql" || true)"
printf '%s' "$setup" | grep -q '"status":"new"' \
	|| die "Zammad reported ${setup}, not status new. A finished setup here means this is not a fresh install."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T zammad-postgresql pg_dump -U zammad -d zammad_production | gzip > "$APP_DIR/backups/zammad-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/zammad-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/zammad-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Zammad is answering at https://${DOMAIN_HOST}/

	  1. One step is left and only you can do it. Open https://${DOMAIN_HOST}
	     and press the button reading "Set up a new system" under the heading
	     "Welcome!", then work through the wizard. It creates the single
	     administrator account. Put that password in your password manager as
	     you type it: this install configures no mail, so there is no reset
	     link.
	  2. Then close the self-signup door Zammad ships open, and check it:
	       cd $APP_DIR
	       docker compose exec -T zammad-railsserver bundle exec rails r "Setting.set('user_create_account', false)"
	       curl -sS -H 'Content-Type: application/json' -d '{"query":"{applicationConfig{key value}}"}' https://${DOMAIN_HOST}/graphql | grep -q user_create_account && echo "signup OPEN" || echo "signup CLOSED"
	     That last line must print signup CLOSED before you hand the address to
	     anybody. Until it does, a stranger who finds the hostname can make
	     themselves an account here.
	  3. One secret lives in $APP_DIR/.env, mode 600, not printed here. No human
	     signs in with it. A database restored beside a different .env does not
	     open, which is why the config archive exists.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive holding compose.yml, .env, storage/ and the Caddy site block.
	     The dump predates your administrator account, so re-run the two backup
	     commands from step 7 of the guide once the wizard is done. Both sit on
	     the same disk as the data, which is not a backup. Copy them somewhere
	     else tonight.
	  5. There is no Elasticsearch here, which upstream calls optional but
	     recommended. Search works over fewer fields than it would with one.

DONE
