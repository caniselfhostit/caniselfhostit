#!/usr/bin/env bash
# Budibase · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=apps.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.budibase.com/docs/docker
#   https://github.com/Budibase/budibase/blob/3.41.3/hosting/single/runner.sh
#   https://github.com/Budibase/budibase/blob/3.41.3/hosting/hosting.properties
#
# Four secrets are generated here, on this machine, into /srv/budibase/.env
# with mode 600, and none of them is ever printed. Three of them close a door:
# the administrator password creates the account during the first boot so no
# stranger can claim the setup form, the CouchDB password replaces a credential
# the base image bakes in as the literal word admin, and the internal API key
# is the credential the server and worker call each other with. The fourth,
# JWT_SECRET, signs session cookies and, with API_ENCRYPTION_KEY unset on this
# shape, is also the key the platform encrypts stored API keys with.
#
# ADMIN_EMAIL is the address that account is created for. Sign in with it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/budibase}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. apps.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address that will own this instance, in lowercase"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 6144 ] || die "only ${avail_mb} MB of RAM available; the all-in-one image wants 6144 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data stays owned by root at mode 755: the container starts as root and then
# chowns data/couch to its CouchDB uid and data/litellm to its PostgreSQL uid,
# and both of those processes have to traverse the parent.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex rather than base64: one of them is typed into a login form by a human and
# the rest ride through a shell that word-splits its own env file. Read the
# administrator password later with
#   sudo grep BB_ADMIN_USER_PASSWORD /srv/budibase/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BB_ADMIN_USER_EMAIL=${ADMIN_EMAIL}
		PLATFORM_URL=https://${DOMAIN_HOST}
		BB_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
		COUCHDB_PASSWORD=$(openssl rand -hex 32)
		INTERNAL_API_KEY=$(openssl rand -hex 32)
		JWT_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-budibase"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8187 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8187 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot pulls over a gigabyte, creates CouchDB's system databases,
# runs PostgreSQL's initdb and LiteLLM's migrations, and only then starts the
# server and worker. This waits fifteen minutes.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 80 budibase"

# Image identity: the build that is running has to be the tag that was pinned.
status="$(curl -sS "https://${DOMAIN_HOST}/api/system/status")"
printf '%s\n' "$status"
printf '%s' "$status" | grep -q '"version":"3.41.3"' \
	|| die "the running build is not 3.41.3. Received: ${status}"

# The administrator must already exist, before the port ever answered a
# stranger. A false here means the BB_ADMIN_USER_ lines never reached the
# container: destroy data/ and start over while nothing is at stake.
checklist="$(curl -sS "https://${DOMAIN_HOST}/api/global/configs/checklist" | grep -o '"adminUser":{"checked":[a-z]*' || true)"
printf '%s\n' "$checklist"
[ "$checklist" = '"adminUser":{"checked":true' ] \
	|| die "no administrator was created. Received: ${checklist:-nothing}. Stop, run: docker compose down && sudo rm -rf ${APP_DIR}/data, then rerun this script."

# The credential the base image bakes in has to be dead.
couch="$(docker compose exec -T budibase curl -sS -o /dev/null -w '%{http_code}' -u admin:admin http://127.0.0.1:5984/_all_dbs)"
printf 'couchdb baked-in credential: %s\n' "$couch"
[ "$couch" = "401" ] || die "the baked-in CouchDB credential still works (received ${couch}). Check COUCHDB_PASSWORD in ${APP_DIR}/.env"

# Caddy has to refuse the path the container's own nginx proxies into CouchDB.
dbpath="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/db/_all_dbs")"
printf '/db/ from the internet: %s\n' "$dbpath"
[ "$dbpath" = "403" ] || die "/db/ answered ${dbpath} instead of 403. Check the site block in /etc/caddy/Caddyfile"

# The container writes its own generated secrets into /data/.env world-readable.
envmode="$(docker compose exec -T budibase sh -c 'chmod 600 /data/.env && stat -c %a /data/.env')"
printf 'container /data/.env mode: %s\n' "$envmode"
[ "$envmode" = "600" ] || die "the container's /data/.env is mode ${envmode}, not 600"

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped, because several storage engines are writing in there and a tar of a
# live CouchDB is a file that resembles a backup.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/budibase-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/budibase-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Budibase 3.41.3 is answering at https://${DOMAIN_HOST}

	  1. Sign in at https://${DOMAIN_HOST} as
	       ${ADMIN_EMAIL}
	     The first screen is headed "Log in to Budibase", not "Create an
	     admin user": the account was created during the first boot, so
	     nobody else could claim this instance.
	  2. Your initial password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep BB_ADMIN_USER_PASSWORD $APP_DIR/.env
	     then change it in your account settings. It was not printed here.
	     There is no mail server on this install, so there is no reset link.
	  3. Keep $APP_DIR/.env. Compose will not start without it, and data
	     restored beside a fresh JWT_SECRET signs every session out and
	     cannot decrypt the API keys the old one encrypted: with
	     API_ENCRYPTION_KEY unset on this shape, JWT_SECRET is that key.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/budibase/
	     Restore is: docker compose down, sudo rm -rf $APP_DIR/data,
	     sudo tar -xzf the archive -C $APP_DIR, docker compose up -d.
	     Untar with sudo, always: the archive carries the uids CouchDB and
	     PostgreSQL own their directories as.

DONE
