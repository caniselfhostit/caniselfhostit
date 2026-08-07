#!/usr/bin/env bash
# Miniflux · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=rss.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://miniflux.app/docs/docker.html
#   https://miniflux.app/docs/configuration.html
#   https://miniflux.app/docs/database.html
#   https://miniflux.app/docs/requirements.html
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the password for your own Miniflux account. Both go into /srv/miniflux/.env
# with mode 600 and neither is ever printed.
#
# DOMAIN_HOST is also BASE_URL. Miniflux builds its session cookie and every
# link it renders from BASE_URL, so a hostname that does not match the address
# in your browser produces a login page that will not log you in.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/miniflux}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_USER="${ADMIN_USER:-admin}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. rss.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Miniflux plus PostgreSQL wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# There is no data directory for Miniflux itself: feeds, entries, read state and
# the account are all rows in PostgreSQL, and the reader writes nothing else.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# The database password is hex because upstream warns that special characters
# can be rejected inside a URL-style connection string unless they are URL
# encoded, and hex has nothing to encode. Read them later with
#   sudo grep -E 'ADMIN_PASSWORD|DB_PASSWORD' /srv/miniflux/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASE_URL=https://${DOMAIN_HOST}
		ADMIN_USERNAME=${ADMIN_USER}
		ADMIN_PASSWORD=$(openssl rand -base64 24)
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-miniflux"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8180 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8180 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Miniflux runs its own SQL migrations on the way up and creates the single
# account from ADMIN_USERNAME and ADMIN_PASSWORD during that same start-up.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthcheck"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthcheck" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/healthcheck answered ${code:-nothing}. Check: docker compose logs --tail 40 miniflux"

curl -sS "https://${DOMAIN_HOST}/healthcheck" | grep -q '^OK$' \
	|| die "/healthcheck answered 200 without the body OK. Check: docker compose logs --tail 40 miniflux"

# The REST API must refuse an unauthenticated call. Upstream answers 401 to a
# request carrying no X-Auth-Token and no basic credentials.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/v1/me" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# The first screen is the sign-in form, and Miniflux offers no way to register.
curl -sS "https://${DOMAIN_HOST}/" | grep -q 'Sign In - Miniflux' \
	|| die "the root page does not carry the sign-in title. Check: docker compose logs --tail 40 miniflux"

docker compose logs miniflux | grep -q 'admin user' \
	|| die "the log shows neither an admin user created nor one skipped. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U miniflux -d miniflux | gzip > "$APP_DIR/backups/miniflux-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/miniflux-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/miniflux-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Miniflux is answering at https://${DOMAIN_HOST}/

	  1. Your username is ${ADMIN_USER}. Read the password once with
	       sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     put it in your password manager, and do not paste it anywhere else.
	     It was not printed here.
	  2. There is no sign-up link, because Miniflux has none. New accounts are
	     made by you, in the admin screen, and nowhere else.
	  3. To read on a phone, open Settings then Integrations and choose a
	     username and password for the Google Reader or Fever API. The server
	     address the app asks for is https://${DOMAIN_HOST} . Upstream names
	     Capy Reader, NetNewsWire and Reeder Classic as Google Reader clients,
	     and Unread, FeedMe and NewsFlash as Fever ones.
	  4. Feeds poll once an hour by default, so a subscription added now can
	     leave the list empty for a while. The refresh button proves it works.
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
