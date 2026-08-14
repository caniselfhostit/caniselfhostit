#!/usr/bin/env bash
# solidtime · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=time.example.com ADMIN_EMAIL=you@example.com \
#     ADMIN_NAME="Your Name" ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.solidtime.io/self-hosting/guides/docker
#   https://docs.solidtime.io/self-hosting/configuration
#   https://docs.solidtime.io/self-hosting/container-mode
#   https://docs.solidtime.io/self-hosting/cli-commands
#
# Four secrets end up on this machine. Three go into /srv/solidtime/.env at mode
# 600: APP_KEY, the Passport private key and the PostgreSQL password. The image
# mints the first two with its own `self-host:generate-keys` command, which is
# why only one of the three comes from `openssl rand` here. The fourth is the
# password on the first account, which the application generates and prints; the
# script sends that output straight into a mode-600 file instead of the
# terminal, and the summary tells you where to read it.
#
# DOMAIN_HOST is also APP_URL. The application rejects any request whose Host
# header is neither that name nor a subdomain of it, so it has to be the name
# you will actually use.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/solidtime}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_NAME="${ADMIN_NAME:-}"
IMAGE="solidtime/solidtime:0.19.1@sha256:419ae59a806bcd6b15e9b637b5cee4800f7eb8f4941e20f4c5416d71acd5f1dd"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. time.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address for the first solidtime account"
[ -n "$ADMIN_NAME" ] || die "set ADMIN_NAME to the display name for the first account, e.g. 'Your Name'"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; three PHP containers plus PostgreSQL want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres stays root-owned: the PostgreSQL image chowns its own data directory
# on first start. storage is chowned to 1000:1000, the uid the application
# containers run as, because that bind mount is the one they write to.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/storage"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the secrets, on the server ----------------------------------
#
# The image's own command mints APP_KEY and the Passport keypair and prints them
# in env-file form, so the redirect below is what keeps them off the terminal.
# Read them later with:
#   sudo grep -E 'APP_KEY|DB_PASSWORD' /srv/solidtime/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	docker run --rm "$IMAGE" php artisan self-host:generate-keys > "$APP_DIR/.env"
	keys="$(grep -c -E '^(APP_KEY|PASSPORT_PRIVATE_KEY|PASSPORT_PUBLIC_KEY)=' "$APP_DIR/.env")"
	[ "$keys" = "3" ] || die "generate-keys wrote ${keys} key lines instead of 3. Inspect $APP_DIR/.env and delete it before retrying."
	cat >> "$APP_DIR/.env" <<-ENVFILE
		APP_ENV="production"
		APP_DEBUG="false"
		APP_URL="https://${DOMAIN_HOST}"
		APP_FORCE_HTTPS="true"
		APP_ENABLE_REGISTRATION="false"
		TRUSTED_PROXIES="172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"
		SUPER_ADMINS="${ADMIN_EMAIL}"
		LOG_CHANNEL="stderr"
		LOG_LEVEL="info"
		DB_CONNECTION="pgsql"
		DB_HOST="postgres"
		DB_DATABASE="solidtime"
		DB_USERNAME="solidtime"
		DB_PASSWORD="$(openssl rand -hex 32)"
		QUEUE_CONNECTION="database"
		MAIL_MAILER="log"
		SCHEDULING_TASK_SELF_HOSTING_CHECK_FOR_UPDATE="false"
		SCHEDULING_TASK_SELF_HOSTING_TELEMETRY="false"
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-solidtime"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8184 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8184 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it, then build the schema --------------------------------------
#
# The health endpoint answers before the schema exists, because it deliberately
# touches neither the database nor the cache. The login page needs the sessions
# table, so the migration has to run before anything else is believed.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health-check/up"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health-check/up" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health-check/up answered ${code:-nothing}. Check: docker compose logs --tail 40 solidtime"

docker compose exec -T solidtime php artisan migrate --force

curl -sS "https://${DOMAIN_HOST}/login" | grep -q '<title inertia>solidtime</title>' \
	|| die "the login page did not carry the solidtime title. Check: docker compose logs --tail 40 solidtime"

# --- 7. The first account, and the closed front door -------------------------
#
# admin:user:create prints a generated password on stdout. That redirect is the
# whole point: the value lands in a file only you can read, never in this log.

if [ ! -f "$APP_DIR/first-account.txt" ]; then
	umask 077
	docker compose exec -T solidtime php artisan admin:user:create "$ADMIN_NAME" "$ADMIN_EMAIL" --verify-email \
		> "$APP_DIR/first-account.txt"
	chmod 600 "$APP_DIR/first-account.txt"
	umask 022
fi
grep -q '^Password: ' "$APP_DIR/first-account.txt" \
	|| die "no password line in $APP_DIR/first-account.txt. Read the file, then delete it and run this again."

reg_env="$(docker compose exec -T solidtime printenv APP_ENABLE_REGISTRATION || echo UNSET)"
echo "==> APP_ENABLE_REGISTRATION inside the container: ${reg_env}"
[ "$reg_env" = "false" ] || die "registration is ${reg_env} inside the container, not false. Fix $APP_DIR/.env and recreate."

reg_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/register" || true)"
echo "==> https://${DOMAIN_HOST}/register answered ${reg_code}"
[ "$reg_code" = "404" ] || die "the signup path answered ${reg_code} instead of 404. Check the Caddy site block."

api_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/users/me" || true)"
echo "==> unauthenticated API call answered ${api_code}"
[ "$api_code" = "401" ] || die "the API answered ${api_code} instead of 401 without a token. Stop and investigate."

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U solidtime -d solidtime \
	| gzip > "$APP_DIR/backups/solidtime-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/solidtime-files-${STAMP}.tar.gz" \
	-C "$APP_DIR" compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/solidtime-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/solidtime-files-${STAMP}.tar.gz" ] || die "the file archive is empty"

cat <<-DONE

	solidtime is answering at https://${DOMAIN_HOST}/login

	  1. Read the password for the first account now:
	       sudo grep '^Password: ' $APP_DIR/first-account.txt
	     It was not printed here. Put it in your password manager, then sign in
	     at https://${DOMAIN_HOST} with ${ADMIN_EMAIL} and confirm the dashboard
	     shows a "This Week" card.
	  2. Once you are signed in, delete that file. It is the only copy on the
	     box and it does not need to stay:
	       shred -u $APP_DIR/first-account.txt
	     If you lose the password afterwards, mail is not configured, so the
	     reset link goes to the container log instead of an inbox:
	       docker compose logs --tail 200 solidtime
	  3. ${ADMIN_EMAIL} is in SUPER_ADMINS, so the same sign-in also opens the
	     server admin panel at https://${DOMAIN_HOST}/admin. That panel can
	     break the instance; it is not where you track time.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding compose.yml, .env, storage and the live Caddy site
	     block. They are on the same disk as the data, which is not a backup.
	     Copy them off the box tonight.

DONE
