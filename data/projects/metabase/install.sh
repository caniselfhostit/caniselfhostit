#!/usr/bin/env bash
# Metabase · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=metabase.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation and source at the
# pinned tag:
#   https://github.com/metabase/metabase/blob/v0.63.2/docs/installation-and-operation/running-metabase-on-docker.md
#   https://github.com/metabase/metabase/blob/v0.63.2/docs/configuring-metabase/environment-variables.md
#   https://github.com/metabase/metabase/blob/v0.63.2/bin/docker/run_metabase.sh
#
# Two secrets are generated here, on this machine: MB_DB_PASS for PostgreSQL,
# and MB_ENCRYPTION_SECRET_KEY, the key Metabase encrypts stored database
# connection details with. Both land in /srv/metabase/.env at mode 600 and
# neither is printed. Losing the encryption key means the connection details in
# a restored application database cannot be decrypted.
#
# This script cannot create the administrator account, because only a browser
# can. It stops with the setup wizard still open and tells you to go and claim
# it. Until you do, the setup token Metabase publishes as a public setting is
# readable by whoever loads the hostname first, and posting it to /api/setup
# makes them the administrator.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/metabase}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. metabase.example.com"
case "$DOMAIN_HOST" in
	*/*) die "DOMAIN_HOST is a hostname, not a URL: no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

# Metabase runs on the JVM, which takes about a quarter of the memory it can
# see as its heap ceiling. Upstream's own Azure guide asks for at least 3.5 GB.
avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; Metabase plus PostgreSQL wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Two owners. The PostgreSQL image chowns its own data directory on first
# start, so that one stays with root. Metabase gets no directory at all: its
# entrypoint drops to uid 2000 and the only path it writes is /plugins inside
# the container, where it re-extracts the bundled Sample Database every start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Read the encryption key later with
#   sudo grep MB_ENCRYPTION_SECRET_KEY /srv/metabase/.env
# and keep it somewhere other than where the backups land.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		MB_SITE_URL=https://${DOMAIN_HOST}
		MB_DB_PASS=$(openssl rand -hex 32)
		MB_ENCRYPTION_SECRET_KEY=$(openssl rand -base64 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-metabase"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8210 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8210 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot runs the whole migration set against an empty PostgreSQL and
# then extracts the Sample Database, so it takes minutes. /api/health answers
# 503 with a progress number until that finishes, which is not a failure.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 metabase"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"status":"ok"' \
	|| die "/api/health did not report status ok. Check: docker compose logs --tail 20 postgres"

# The title Metabase renders into its own page. Its absence means Caddy is
# reaching something other than Metabase.
curl -sSL "https://${DOMAIN_HOST}/" | grep -q '<title>Metabase</title>' \
	|| die "https://${DOMAIN_HOST}/ is not serving Metabase's own page"

# With no user in the database, has-user-setup is false and the setup token is
# published to anyone who asks. Confirming it is there is the last assert here;
# closing it is the first thing you do next.
props="$(curl -sS "https://${DOMAIN_HOST}/api/session/properties")"
printf '%s' "$props" | grep -q '"has-user-setup":false' \
	|| die "has-user-setup is already true; a user exists on this instance and it is not yours"
printf '%s' "$props" | grep -q '"setup-token":"' \
	|| die "no setup token is published, so the wizard cannot be completed. Check the container logs."
unset props

# --- 7. The first backup, before day one ends --------------------------------
#
# Two artifacts. pg_dump snapshots a running database consistently, so nothing
# is stopped. The config archive carries the live Caddy site block and the .env
# holding the key that decrypts stored connection details.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U metabase -d metabase | gzip > "$APP_DIR/backups/metabase-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/metabase-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/metabase-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/metabase-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Metabase is answering at https://${DOMAIN_HOST}

	  1. Do this now, before anything else: open
	       https://${DOMAIN_HOST}/setup
	     and complete the wizard to create the administrator account. Until you
	     do, Metabase publishes a setup token as a public setting, and whoever
	     reads it can post it to /api/setup and become the administrator of
	     this instance. Use a password from your password manager, twenty
	     characters or more: upstream's shipped rule accepts six characters
	     with one digit.
	  2. Then prove the door is shut. Both of these must be true:
	       curl -sS https://${DOMAIN_HOST}/api/session/properties | grep -oE '"(has-user-setup|setup-token)":[a-z]*'
	     should print "has-user-setup":true and "setup-token":null.
	  3. Your MB_ENCRYPTION_SECRET_KEY is in $APP_DIR/.env, mode 600. Read it
	     with
	       sudo grep MB_ENCRYPTION_SECRET_KEY $APP_DIR/.env
	     and put it in your password manager, somewhere other than where these
	     backups land. It was not printed here. Without it, the connection
	     details in a restored database cannot be decrypted.
	  4. Two databases now exist and they do different jobs. The PostgreSQL
	     this script started holds your accounts, questions and dashboards.
	     The data you analyse lives in whatever you connect under Admin >
	     Databases, is read live over the network, and is never copied here or
	     into these backups.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy both files somewhere else
	     tonight.

DONE
