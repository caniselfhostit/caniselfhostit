#!/usr/bin/env bash
# AdventureLog · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=trips.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/documentation/docs/install/docker.md
#   https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/.env.example
#   https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/documentation/docs/install/caddy.md
#   https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/documentation/docs/configuration/disable_registration.md
#
# Three secrets are generated here, on this machine: the PostgreSQL password,
# Django's SECRET_KEY, and the password for the admin account the backend
# creates on first boot. All three go into /srv/adventurelog/.env with mode 600
# and none is ever printed.
#
# DOMAIN_HOST becomes ORIGIN, PUBLIC_URL, FRONTEND_URL and CSRF_TRUSTED_ORIGINS
# in that one file, and it fronts every image URL, so changing it later is an
# edit in four places.
#
# This install is amd64 only. PostGIS is required by AdventureLog and the
# postgis/postgis image publishes linux/amd64 only.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/adventurelog}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. trips.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this server is ${arch}; PostGIS publishes no ARM image, so this install stops here"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; the first boot imports world geography data and wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# media stays root-owned: the backend container runs as root and writes the
# photographs and the country flags into it. postgres stays root-owned because
# the database image chowns its own data directory on first start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 "$APP_DIR/media"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64: one of them travels inside a database connection
# string. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|SECRET_KEY|DJANGO_ADMIN_PASSWORD' /srv/adventurelog/.env
#
# DEBUG defaults to true in the image, DISABLE_REGISTRATION closes a sign-up
# form that is otherwise open on a public hostname, and ENABLE_RATE_LIMITS
# defaults to false and switches on upstream's throttle for failed logins.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PUBLIC_SERVER_URL=http://server:8000
		ORIGIN=https://${DOMAIN_HOST}
		BODY_SIZE_LIMIT=Infinity
		PGHOST=db
		POSTGRES_DB=adventurelog
		POSTGRES_USER=adventurelog
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		SECRET_KEY=$(openssl rand -hex 48)
		DJANGO_ADMIN_USERNAME=admin
		DJANGO_ADMIN_PASSWORD=$(openssl rand -hex 24)
		DJANGO_ADMIN_EMAIL=admin@${DOMAIN_HOST}
		PUBLIC_URL=https://${DOMAIN_HOST}
		FRONTEND_URL=https://${DOMAIN_HOST}
		CSRF_TRUSTED_ORIGINS=https://${DOMAIN_HOST}
		DEBUG=False
		DISABLE_REGISTRATION=True
		ENABLE_RATE_LIMITS=True
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------
#
# One hostname, two upstreams: the Django backend answers /media, /admin,
# /static and /accounts, the frontend answers everything else.

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-adventurelog"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8168, 8268 or 5432 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8168, 8268 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The backend migrates, creates the admin account from the DJANGO_ADMIN_ values,
# then downloads the world country and region dataset and a flag image for every
# country before it serves anything. That is minutes on a first boot.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ (the world-data import runs first)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the site answered ${code:-nothing}. Check: docker compose logs --tail 40 server (exit code 137 means it ran out of memory)"

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>AdventureLog</title>' \
	|| die "the root URL did not serve the AdventureLog page. Check that Caddy is reaching 127.0.0.1:8168"

# Proves Caddy routes the four backend paths to 8268 rather than sending
# everything to the frontend. Get this wrong and every photograph is missing.
admin_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/admin/login/" || true)"
[ "$admin_code" = "200" ] || die "https://${DOMAIN_HOST}/admin/login/ returned ${admin_code}, not 200. The @backend matcher in the Caddy block did not land."

# The security assert: registration must be closed on a public hostname.
curl -sS "http://127.0.0.1:8268/auth/is-registration-disabled/" | grep -q '"is_disabled":true' \
	|| die "registration is still open. Stop: DISABLE_REGISTRATION did not reach the container."

countries="$(docker compose exec -T db psql -U adventurelog -d adventurelog -tAc 'SELECT count(*) FROM worldtravel_country;' | tr -dc '0-9')"
[ "${countries:-0}" -ge 195 ] || die "only ${countries:-0} countries imported. The world-data import did not finish; check docker compose logs --tail 40 server"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U adventurelog -d adventurelog | gzip > "$APP_DIR/backups/adventurelog-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/adventurelog-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env media -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/adventurelog-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	AdventureLog is answering at https://${DOMAIN_HOST}

	  1. Sign in at https://${DOMAIN_HOST}/login as the user admin. Read the
	     password with
	       sudo grep DJANGO_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and no
	     mail server on this box can send you a reset link.
	  2. Registration is closed, and this script asserted it before finishing.
	     To add a second traveller, create the account yourself in the Django
	     admin at https://${DOMAIN_HOST}/admin/ rather than reopening sign-up.
	  3. Your maps are drawn from tiles fetched by your browser from
	     basemaps.cartocdn.com, and the country flags came from flagcdn.com
	     during the first boot. Nothing about your trips is sent to either, but
	     the requests happen and they are not requests you are hosting.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive holding compose.yml, .env, media and the Caddy config. They are
	     on the same disk as the data, which is not a backup. Copy them
	     somewhere else tonight, and copy both: the photographs are in media and
	     everything saying which trip they belong to is in the database.

DONE
