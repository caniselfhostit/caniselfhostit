#!/usr/bin/env bash
# wger · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=wger.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://wger.readthedocs.io/en/latest/installation/docker.html
#   https://wger.readthedocs.io/en/latest/administration/settings.html
#   https://wger.readthedocs.io/en/latest/administration/errors.html
#   https://wger.readthedocs.io/en/latest/development/architecture.html
#
# Four secrets are generated on this machine: Django's SECRET_KEY, the
# PostgreSQL password, a password for the admin account the image creates, and
# an RSA keypair for signing API tokens that wger's own command produces. All
# four land in /srv/wger/.env with mode 600 and none is ever printed.
#
# The account the image bootstraps is admin, with a password upstream prints in
# its install guide. This script replaces it and then checks the published one
# is refused before it reports success.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/wger}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. wger.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

# compose.yml carries its nginx configuration in a `configs:` block with inline
# content, which Docker Compose learned to read in 2.23.
compose_ver="$(docker compose version --short | tr -d 'v')"
[ "$(printf '%s\n2.23.0\n' "$compose_ver" | sort -V | head -1)" = "2.23.0" ] \
	|| die "docker compose ${compose_ver} is older than 2.23, which cannot read an inline config block"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Django plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# static and media belong to uid and gid 1000 because that is the user inside
# the image, and upstream requires both folders to be readable by everyone or
# the site loads with no styling at all.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 755 -o 1000 -g 1000 "$APP_DIR/static" "$APP_DIR/media"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the secrets, on the server ----------------------------------
#
# Hex for all three: every one of them passes through a file that a shell and a
# compose parser both read, and neither wants escaping. Read them later with
#   grep -E 'WGER_ADMIN_PASSWORD' /srv/wger/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SITE_URL=https://${DOMAIN_HOST}
		CSRF_TRUSTED_ORIGINS=https://${DOMAIN_HOST}
		TIME_ZONE=UTC
		TZ=UTC
		SECRET_KEY=$(openssl rand -hex 32)
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		WGER_ADMIN_PASSWORD=$(openssl rand -hex 20)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

# The fourth secret is an RSA keypair, and only wger makes it in the shape it
# wants. Upstream ships a working keypair in its public repository and says in
# the same paragraph that it has to be replaced.
if ! grep -q '^JWT_PRIVATE_KEY=' "$APP_DIR/.env"; then
	echo "==> generating a JWT keypair (this pulls the image, give it a few minutes)"
	docker run --rm wger/server:2.6.0@sha256:e7f58e15d380d8f5edc055c8a1ed11199e7eb5649138670703401b0c9c407c01 \
		python3 manage.py generate-jwt-keys | grep -E '^JWT_(PRIVATE|PUBLIC)_KEY=' >> "$APP_DIR/.env"
fi
[ "$(grep -c '^JWT_' "$APP_DIR/.env")" = "2" ] || die "the JWT keypair was not written to $APP_DIR/.env"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-wger"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8147, 5432 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8147, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start migrates the database, loads the exercise fixtures, creates
# the admin account and runs collectstatic before gunicorn answers anything.
# Upstream's own health check allows five minutes for that.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v2/version/ (this takes minutes on a first run)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v2/version/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/v2/version/ answered ${code:-nothing}. Check: docker compose logs --tail 40 web"

curl -sS "https://${DOMAIN_HOST}/api/v2/version/" | grep -q '"2.6.0"' \
	|| die "the version endpoint answered 200 without 2.6.0. Check: docker compose logs --tail 40 web"

# The admin account the image bootstrapped has a password upstream publishes.
# Replace it with the generated one and prove the published one is dead. The
# new value is read from the container's environment, so it is never printed.
rotated="$(docker compose exec -T web python3 manage.py shell -c "import os;from django.contrib.auth.models import User;u=User.objects.get(username='admin');u.set_password(os.environ['WGER_ADMIN_PASSWORD']);u.save();u.refresh_from_db();print('default rejected' if not u.check_password('adminadmin') else 'DEFAULT STILL ACCEPTED')" | tr -d '\r\n')"
[ "$rotated" = "default rejected" ] || die "the admin password was not rotated (${rotated}). This box is on the internet with a published credential."

# A food database to start from. Upstream calls this the small base set; the
# full one is around 1 GB of database and hours of work, and is not run here.
docker compose exec -T web wger load-online-fixtures

ingredients="$(curl -sS "https://${DOMAIN_HOST}/api/v2/ingredient/?limit=1" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
[ -n "$ingredients" ] && [ "$ingredients" -gt 0 ] || die "the ingredient table is empty; the fixture load did not finish"

curl -sS "https://${DOMAIN_HOST}/en/user/login" -o /tmp/wger-login.html
grep -q '<h2 class="mb-1">Login</h2>' /tmp/wger-login.html \
	|| die "the login page did not contain the Login heading. Check: docker compose logs --tail 20 nginx"
grep -q 'user/registration' /tmp/wger-login.html \
	&& die "the login page still offers registration; ALLOW_REGISTRATION did not take effect" || true

# The assert that matters most: the stylesheet the page asks for has to load,
# or the site renders as unformatted text and nothing logs an error.
asset="$(grep -oE '/static/[^"]+\.css' /tmp/wger-login.html | head -1)"
[ -n "$asset" ] || die "the login page referenced no stylesheet at all"
css_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}${asset}" || true)"
[ "$css_code" = "200" ] || die "${asset} answered ${css_code}: static files are not being served, see the ownership of ${APP_DIR}/static"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U wger -d wger | gzip > "$APP_DIR/backups/wger-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/wger-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env media -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/wger-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	wger is answering at https://${DOMAIN_HOST}/en/user/login

	  1. Log in as admin. The password is in $APP_DIR/.env, mode 600. Read it
	     with
	       grep WGER_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and the
	     one upstream publishes no longer works.
	  2. Registration is closed and there is one account. The exercise database
	     came with the image; the food database is the small base set, ${ingredients}
	     ingredients. The full one is around 1 GB and hours of work:
	       docker compose exec web ./manage.py sync-ingredients-bulk --set-mode insert
	  3. The phone app in the stores syncs through a service this install does
	     not run, so it will log in and then report sync unavailable. The web
	     interface works in a phone browser.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
