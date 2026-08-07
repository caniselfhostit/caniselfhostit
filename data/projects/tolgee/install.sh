#!/usr/bin/env bash
# Tolgee · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=tolgee.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.tolgee.io/platform/self_hosting/running_with_docker
#   https://docs.tolgee.io/platform/self_hosting/configuration
#   https://github.com/tolgee/tolgee-platform/blob/v3.218.0/docker/app/Dockerfile
#
# Three secrets are generated here, on this machine: the PostgreSQL password,
# the JWT signing secret, and the password of the admin account Tolgee creates
# on its first start. All three go into /srv/tolgee/.env with mode 600 and none
# of them is ever printed.
#
# The check that matters is the one at the end: with TOLGEE_AUTHENTICATION_ENABLED
# unset, the tolgee/tolgee image has no login screen and hands every caller a
# session as the administrator. This script refuses to finish until an
# anonymous request comes back as nobody.
#
# DOMAIN_HOST is also TOLGEE_FRONT_END_URL and the apiUrl every SDK you point at
# this server will carry. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/tolgee}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. tolgee.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; a JVM plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64: the JWT secret is taken as raw bytes and upstream
# requires at least 32 characters, and the other two travel inside a JDBC
# connection string. Read the admin password later with
#   sudo grep TOLGEE_AUTHENTICATION_INITIAL_PASSWORD /srv/tolgee/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		TOLGEE_FRONT_END_URL=https://${DOMAIN_HOST}
		DB_PASSWORD=$(openssl rand -hex 32)
		TOLGEE_AUTHENTICATION_JWT_SECRET=$(openssl rand -hex 32)
		TOLGEE_AUTHENTICATION_INITIAL_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-tolgee"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8178, 5432 or 25432 is one of them ------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8178, 5432 and 25432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Tolgee runs its own schema migrations on the way up. A JVM starting cold on a
# small VPS takes over a minute before it answers anything.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/public/configuration"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/public/configuration" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/public/configuration answered ${code:-nothing}. Check: docker compose logs --tail 40 tolgee"

conf="$(curl -sS "https://${DOMAIN_HOST}/api/public/configuration" || true)"
printf '%s' "$conf" | grep -q '"version":"v3.218.0"' \
	|| die "the running version is not v3.218.0. Check the image line in $APP_DIR/compose.yml"
printf '%s' "$conf" | grep -q '"allowRegistrations":false' \
	|| die "self-registration is open. Stop and investigate before anyone finds this hostname."

# --- 7. The assert this whole install turns on -------------------------------
#
# With authentication disabled, Tolgee gives an anonymous caller a super-powered
# session as the administrator, so /v2/public/initial-data comes back with a
# populated userInfo object. null is the only acceptable answer here.

printf '%s' "$conf" | grep -q '"authentication":true' \
	|| die "authentication is disabled: this hostname has no login screen. Check TOLGEE_AUTHENTICATION_ENABLED in $APP_DIR/compose.yml"

curl -sS "https://${DOMAIN_HOST}/v2/public/initial-data" | grep -q '"userInfo":null' \
	|| die "an anonymous request was answered as a logged-in user. Stop and investigate."

blocked="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/actuator/prometheus" || true)"
[ "$blocked" = "403" ] || die "/actuator/prometheus returned ${blocked}, not 403. The Caddy site block did not take."

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U tolgee -d tolgee | gzip > "$APP_DIR/backups/tolgee-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/tolgee-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/tolgee-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Tolgee is answering at https://${DOMAIN_HOST}

	  1. Sign in with the username admin. The login box is labelled Email and
	     the account is not an email address; type admin into it anyway. Your
	     password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep TOLGEE_AUTHENTICATION_INITIAL_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and
	     there is no mail server, so there is no reset link.
	  2. Authentication was checked, not assumed: an anonymous request to
	     /v2/public/initial-data came back as nobody, and self-registration is
	     off. Leave both that way.
	  3. Nothing is translated yet. Create a project, add your languages, make
	     a project API key in its settings, and point your application's Tolgee
	     SDK at apiUrl https://${DOMAIN_HOST} with that key. The key can edit
	     translations, so keep it in a development configuration.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive that includes .env. The JWT secret in that file validates every
	     session already issued, so the two files are one backup. They are on
	     the same disk as the data, which is not a backup. Copy them somewhere
	     else tonight.

DONE
