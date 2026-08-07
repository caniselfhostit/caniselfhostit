#!/usr/bin/env bash
# Kener · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=status.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://kener.ing/docs/v4/setup/deployment
#   https://kener.ing/docs/v4/setup/environment-variables
#   https://kener.ing/docs/v4/setup/database-setup
#   https://github.com/rajnandan1/kener/blob/v4.1.2/Dockerfile
#
# One secret is generated here, on this machine: KENER_SECRET_KEY, which signs
# the session tokens and encrypts stored credentials. It goes into
# /srv/kener/.env with mode 600 and is never printed.
#
# DOMAIN_HOST is also ORIGIN, the address SvelteKit compares every form post
# against. It takes no trailing slash, and a mismatch shows up as a sign-in that
# fails on a page that loads.
#
# This script cannot create the administrator account, because only a browser
# can. It stops with the setup form still open and tells you to go and claim it.
# Until you do, whoever loads the hostname first can.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/kener}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. status.example.com"
case "$DOMAIN_HOST" in
	*/*) die "DOMAIN_HOST is a hostname, not a URL: no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Kener plus Redis wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Three owners, on purpose. The Kener image runs as the node user, uid 1000, so
# it cannot write a database directory owned by the login user. The redis image
# chowns its own data directory on first start, so that one stays with root.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/database"
sudo install -d -m 750 "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Upstream documents `openssl rand -base64 32` for this key. Read it later with
#   sudo grep KENER_SECRET_KEY /srv/kener/.env
# Changing it signs everyone out and makes anything encrypted under it
# unreadable, so put it in a password manager the day you run this.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		ORIGIN=https://${DOMAIN_HOST}
		TZ=UTC
		KENER_SECRET_KEY=$(openssl rand -base64 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-kener"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8179 nor 6379 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8179 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Kener runs its migrations and its seed on the way up, so the first boot writes
# the schema and a starter status page before it answers anything.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthcheck?strict=1"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthcheck?strict=1" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/healthcheck?strict=1 answered ${code:-nothing}. Check: docker compose logs --tail 40 kener"

# The plain endpoint answers 200 even when a dependency is down, so the body is
# the real assert: db and redis both have to be true.
curl -sS "https://${DOMAIN_HOST}/healthcheck" | grep -q '"status":"ok"' \
	|| die "/healthcheck did not report status ok. Check: docker compose logs --tail 20 redis"

# The heading the seeded status page renders. Its absence means Caddy is
# reaching something other than Kener.
curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Service Status' \
	|| die "the page at https://${DOMAIN_HOST}/ does not carry the status page heading"

# The API must refuse a call carrying no bearer token.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/monitors" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# With no users in the database, the sign-in page is a setup form. Confirming it
# is there is the last assert; closing it is the first thing you do next.
curl -sSL "https://${DOMAIN_HOST}/account/signin" | grep -q 'Create Admin Account' \
	|| die "https://${DOMAIN_HOST}/account/signin is not offering the setup form; a user may already exist"

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped on purpose: a SQLite file copied mid-write is not a backup. Downtime
# is a few seconds. Redis is not in the archive, because it holds queue state
# that rebuilds itself.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/kener-${STAMP}.tar.gz" -C "$APP_DIR" database .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/kener-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Kener is answering at https://${DOMAIN_HOST}

	  1. Do this now, before anything else: open
	       https://${DOMAIN_HOST}/account/signin
	     and create the administrator account. Until you do, that form is a
	     Create Admin Account form for whoever loads the hostname first.
	     Upstream refuses a second signup once one user exists, so claiming it
	     closes the window for good.
	  2. That status page is public. It has no login, and every monitor name
	     and description you add is on it. Open it in a private window and read
	     it as a stranger would before you add anything internal.
	  3. Your KENER_SECRET_KEY is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep KENER_SECRET_KEY $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  4. Keep one free external check pointed at https://${DOMAIN_HOST} from a
	     service you do not run. This box cannot tell you that this box is down.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
