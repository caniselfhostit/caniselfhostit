#!/usr/bin/env bash
# GlitchTip · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=errors.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://glitchtip.com/documentation/install
#   https://glitchtip.com/assets/compose.sample.yml
#   https://gitlab.com/glitchtip/glitchtip-backend/-/tree/v6.2.3
#
# Two secrets are generated here, on this machine: the Django SECRET_KEY and the
# PostgreSQL credential. Both go into /srv/glitchtip/.env with mode 600 and
# neither is ever printed. Read them yourself with
#   sudo grep -E 'SECRET_KEY|DB_PASSWORD' /srv/glitchtip/.env
#
# DOMAIN_HOST becomes GLITCHTIP_DOMAIN, and every DSN this server hands out is
# built from it. Choose it once. Changing it later means editing every
# application that reports here.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/glitchtip}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. errors.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; GlitchTip plus PostgreSQL and Valkey wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays root-owned at 700: the PostgreSQL image chowns its own data
# directory the first time it starts. uploads belongs to uid 5000, which is the
# account the GlitchTip image runs as and the only one that can write there.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 750 -o 5000 -g 5000 "$APP_DIR/uploads"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# ALLOWED_HOSTS carries localhost as well as the real hostname, because the
# container health check calls http://localhost:8000/_health/ from inside itself
# and Django answers 400 to a Host header it was not told about.
# CSRF_TRUSTED_ORIGINS is what upstream documents as required behind a proxy.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		GLITCHTIP_DOMAIN=https://${DOMAIN_HOST}
		ALLOWED_HOSTS=${DOMAIN_HOST},localhost
		CSRF_TRUSTED_ORIGINS=https://${DOMAIN_HOST}
		SECRET_KEY=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-glitchtip"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8123, 5432 or 6379 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8123, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# SERVER_ROLE all_in_one means the web container applies the migrations and
# builds the event partitions before it binds a port, so the first start takes
# minutes rather than seconds.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/_health/"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/_health/" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/_health/ answered ${code:-nothing}. Check: docker compose logs --tail 40 web"

curl -sS "https://${DOMAIN_HOST}/_health/" | grep -qx 'ok' \
	|| die "/_health/ answered 200 without the body ok. Check: docker compose logs --tail 40 web"

# The API must refuse a call carrying no credential.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/0/organizations/" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# Django Admin is disabled in compose.yml, so it must not be routed at all.
admin="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/admin/" || true)"
[ "$admin" = "404" ] || die "/admin/ returned ${admin}, not 404. ENABLE_ADMIN is not taking effect."

# Self-signup is off in compose.yml, and upstream opens it only while the user
# table is empty. This script cannot create the first account, so true is the
# correct answer here and the summary below tells you how to close it.
signup="$(curl -sS "https://${DOMAIN_HOST}/api/settings/" | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*' || true)"
[ "$signup" = '"enableUserRegistration":true' ] || die "/api/settings/ reported ${signup:-nothing}. Expected the sign-up door open on an empty instance."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U glitchtip -d glitchtip | gzip > "$APP_DIR/backups/glitchtip-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/glitchtip-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/glitchtip-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	GlitchTip is answering at https://${DOMAIN_HOST}/_health/

	  1. Open https://${DOMAIN_HOST} and follow Sign Up now. Self-signup is off,
	     and upstream keeps it open only while no account exists, so this is the
	     one and only registration this instance will accept. Save the password
	     in a password manager first: no mail is configured, so there is no
	     reset link. Create the organization it asks for next, then confirm the
	     door is shut with
	       curl -sS https://${DOMAIN_HOST}/api/settings/ | tr -d ' ' | grep -o '"enableUserRegistration":[a-z]*'
	     which must print "enableUserRegistration":false.
	  2. Then make a project. Its DSN is what your application's Sentry SDK
	     points at, and it is the whole reason this server exists.
	  3. Your SECRET_KEY and database credential are in $APP_DIR/.env, mode 600.
	     They were not printed here. Read them with
	       sudo grep -E 'SECRET_KEY|DB_PASSWORD' $APP_DIR/.env
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
