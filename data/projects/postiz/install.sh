#!/usr/bin/env bash
# Postiz · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=postiz.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.postiz.com/installation/docker-compose
#   https://docs.postiz.com/configuration/reference
#   https://docs.postiz.com/installation/system-requirements
#   https://docs.postiz.com/reverse-proxies/caddy
#
# Three secrets are generated here, on this machine: a password for each of the
# two PostgreSQL services and the key that signs session tokens. All three go
# into /srv/postiz/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST is the host inside every OAuth redirect URI you will register at X,
# Meta, LinkedIn and every other network. Choose it once. Changing it later means
# editing each of those developer apps by hand.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/postiz}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. postiz.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; five containers want 4096 MB, and a machine sold as 4 GB rarely clears that: use 8 GB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/config" "$APP_DIR/uploads"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/temporal-postgres" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64: two of the three travel inside connection strings.
# Read them later with
#   sudo cat /srv/postiz/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		POSTIZ_DOMAIN=${DOMAIN_HOST}
		POSTIZ_DB_PASSWORD=$(openssl rand -hex 32)
		TEMPORAL_DB_PASSWORD=$(openssl rand -hex 32)
		JWT_SECRET=$(openssl rand -hex 48)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-postiz"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8111, 5432, 6379 and 7233 are not among them ----

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8111, 5432, 6379 and 7233 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start is the slow one: Temporal builds two database schemas before it
# reports healthy, and Postiz then runs its own migrations.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/ (up to ten minutes)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/ answered ${code:-nothing}. Check: docker compose logs --tail 40 postiz"

docker compose exec -T temporal temporal operator cluster health --address temporal:7233 | grep -q SERVING \
	|| die "the Temporal cluster is not SERVING. Check: docker compose logs --tail 40 temporal"

curl -sS "https://${DOMAIN_HOST}/api/" | grep -q 'App is running!' \
	|| die "/api/ answered 200 without the expected body. Check: docker compose logs --tail 40 postiz"

# The sign-up window must be open exactly once, and only while the database is
# empty. Upstream documents DISABLE_REGISTRATION as allowing a single signup and
# then disabling the sign-up page.
reg="$(curl -sS "https://${DOMAIN_HOST}/api/auth/can-register" || true)"
case "$reg" in
	*'"register":true'*) SIGNUP_OPEN=yes ;;
	*'"register":false'*) SIGNUP_OPEN=no ;;
	*) die "/api/auth/can-register answered '${reg}'. Stop and investigate." ;;
esac

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postiz-postgres pg_dump -U postiz -d postiz | gzip > "$APP_DIR/backups/postiz-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/postiz-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env config uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/postiz-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Postiz is answering at https://${DOMAIN_HOST}/api/

	  1. Sign-up window open: ${SIGNUP_OPEN}. If it says yes, open
	       https://${DOMAIN_HOST}/auth
	     and create your account now. The first screen shows the heading
	     "Sign Up" and a "Create Account" button. That one signup is the only
	     one this install allows: DISABLE_REGISTRATION is true, so the page
	     closes itself afterwards. Confirm it with
	       curl -sS https://${DOMAIN_HOST}/api/auth/can-register
	     which should answer {"register":false} once your account exists.
	  2. No social network is connected, and this script cannot connect one.
	     Every network needs an app you register in that company's own developer
	     portal, with a redirect URI of
	       https://${DOMAIN_HOST}/integrations/social/
	     and its client id and secret added to $APP_DIR/.env. Several of those
	     registrations are reviewed by a person at the other company and take
	     days. Start at https://docs.postiz.com/providers/overview.
	  3. Your three secrets are in $APP_DIR/.env, mode 600. Read them with
	       sudo cat $APP_DIR/.env
	     They were not printed here.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
