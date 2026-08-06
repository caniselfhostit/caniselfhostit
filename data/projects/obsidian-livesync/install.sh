#!/usr/bin/env bash
# Obsidian LiveSync · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=notes.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md
#   https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/quick_setup.md
#   https://github.com/vrtmrz/obsidian-livesync/blob/main/utils/couchdb/provision.ts
#   https://docs.couchdb.org/en/stable/config/http.html
#
# What this installs is Apache CouchDB, the sync server the Obsidian Self-hosted
# LiveSync plugin replicates into. It cannot install the plugin: that happens by
# hand, inside Obsidian, on every device you want synchronised. The closing
# summary tells you what to do there.
#
# Two secrets are generated here, on this machine: the CouchDB administrator
# password and the session-cookie secret. Both go into /srv/obsidian-livesync/.env
# with mode 600 and neither is ever printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/obsidian-livesync}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
DB_NAME="${DB_NAME:-obsidiannotes}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. notes.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; CouchDB wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The data directory belongs to uid 5984 because the CouchDB image creates a
# couchdb account at that uid and compose.yml runs the container as it.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 -o 5984 -g 5984 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: one is typed into a settings field on a phone
# and neither wants escaping. Read the two you need with
#   sudo grep -E 'COUCHDB_USER|COUCHDB_PASSWORD' /srv/obsidian-livesync/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		COUCHDB_USER=livesync
		COUCHDB_PASSWORD=$(openssl rand -hex 32)
		COUCHDB_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null \
	|| die "compose rejected the file. An error naming 'content' means the compose plugin predates v2.23.1; upgrade it."

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-obsidian-livesync"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8120 nor 5984 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8120 and 5984 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/_up"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/_up" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/_up answered ${code:-nothing}. Check: docker compose logs --tail 40 couchdb"

curl -sS "https://${DOMAIN_HOST}/_up" | grep -q '"status":"ok"' \
	|| die "/_up answered 200 without status ok. Check: docker compose logs --tail 40 couchdb"

# Every path but /_up must refuse a request that carries no credential. A 200
# here would mean the database is open to the internet.
anon="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$anon" = "401" ] || die "an unauthenticated request to / returned ${anon}, not 401. Stop and investigate."

# The database the plugin replicates into. The credential goes to curl on stdin,
# so it never appears in the process list.
set -a
# shellcheck disable=SC1091
. "$APP_DIR/.env"
set +a
created="$(printf 'user = "%s:%s"\n' "$COUCHDB_USER" "$COUCHDB_PASSWORD" \
	| curl -sS -K - -X PUT "https://${DOMAIN_HOST}/${DB_NAME}" || true)"
case "$created" in
	*'"ok":true'*|*file_exists*) : ;;
	*) die "creating the ${DB_NAME} database failed: ${created}" ;;
esac
COUCHDB_USER_NAME="$COUCHDB_USER"
unset COUCHDB_USER COUCHDB_PASSWORD COUCHDB_SECRET

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/obsidian-livesync-${STAMP}.tar.gz" -C "$APP_DIR" data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/obsidian-livesync-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	CouchDB is answering at https://${DOMAIN_HOST}/_up and the ${DB_NAME}
	database exists. Nothing syncs yet: the other half is a plugin only you
	can install.

	  1. Read your credentials, in your own terminal, and put them in your
	     password manager. They were not printed here:
	       sudo grep -E 'COUCHDB_USER|COUCHDB_PASSWORD' $APP_DIR/.env
	     The username is ${COUCHDB_USER_NAME}.
	  2. In Obsidian, back up the vault, then turn off Obsidian Sync, iCloud
	     and anything else writing to it. Two synchronisers on one vault
	     duplicate and corrupt notes.
	  3. Settings, Community plugins, turn off Restricted mode, Browse,
	     install and enable Self-hosted LiveSync. Open the welcome notice,
	     choose to set up for the first time, then Configure a remote
	     manually. Turn End-to-End Encryption on and enter a passphrase you
	     have written down: it never reaches this server and nothing here can
	     recover it. Choose CouchDB, enter https://${DOMAIN_HOST}, the
	     credentials from step 1, and the database name ${DB_NAME}.
	  4. Create one note, then check it arrived:
	       cd $APP_DIR && set -a && . ./.env && set +a
	       printf 'user = "%s:%s"\n' "\$COUCHDB_USER" "\$COUCHDB_PASSWORD" | curl -sS -K - https://${DOMAIN_HOST}/${DB_NAME}
	     doc_count above 0 is this install working end to end.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight, and
	     keep the encryption passphrase alongside the CouchDB credentials,
	     because the archive is ciphertext without it.

DONE
