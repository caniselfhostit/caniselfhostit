#!/usr/bin/env bash
# Appsmith · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=apps.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.appsmith.com/getting-started/setup/installation-guides/docker
#   https://docs.appsmith.com/getting-started/setup/environment-variables
#   https://docs.appsmith.com/getting-started/setup/infrastructure-sizing
#   https://docs.appsmith.com/getting-started/setup/instance-management/appsmithctl
#
# Two secrets are generated here, on this machine: the encryption password and
# the encryption salt. Both go into /srv/appsmith/.env with mode 600 and neither
# is ever printed. They encrypt every datasource credential the instance stores,
# so a data directory restored without them comes back undecryptable.
#
# ADMIN_EMAIL is the only address that will be able to create an account, because
# this install closes signup before the container's first boot and names that
# address as the exception. Use it verbatim in the welcome form.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/appsmith}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. apps.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address that will own this instance, in lowercase"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 8192 ] || die "only ${avail_mb} MB of RAM available; the all-in-one image wants 8192 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# stacks stays owned by root: the container starts as root and hands its
# embedded PostgreSQL a data directory it chowns to its own uid.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 "$APP_DIR/stacks"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64: both travel through a Java property loader and neither
# wants escaping. Read them later with
#   sudo grep -E 'ENCRYPTION_PASSWORD|ENCRYPTION_SALT' /srv/appsmith/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APPSMITH_ADMIN_EMAILS=${ADMIN_EMAIL}
		APPSMITH_SIGNUP_DISABLED=true
		APPSMITH_BASE_URL=https://${DOMAIN_HOST}
		APPSMITH_ENCRYPTION_PASSWORD=$(openssl rand -hex 32)
		APPSMITH_ENCRYPTION_SALT=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-appsmith"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8143 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8143 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot initialises MongoDB, Redis and PostgreSQL inside the container
# and runs the server's migrations. Upstream says up to five minutes; this waits
# fifteen.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/health"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/v1/health answered ${code:-nothing}. Check: docker compose logs --tail 60 appsmith"

curl -sS "https://${DOMAIN_HOST}/api/v1/health" | grep -q '"data":"All systems are up"' \
	|| die "health answered 200 without the expected body. Check: docker compose logs --tail 60 appsmith"

# Signup must already be shut, before any account exists. This value is written
# into the database on the first boot only, so a false here is not fixable by
# editing .env: destroy stacks/ and start over while nothing is at stake.
curl -sS "https://${DOMAIN_HOST}/api/v1/tenants/current" | grep -q '"isSignupDisabled":true' \
	|| die "signup is still open. Stop, run: docker compose down && sudo rm -rf ${APP_DIR}/stacks, then rerun this script."

# The container serves its own holding page until the server is ready. Once the
# real editor is being served, that string is gone.
if curl -sS "https://${DOMAIN_HOST}/" | grep -q 'Appsmith is starting.'; then
	die "the holding page is still being served. Wait, then re-run the health check."
fi

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped, because three database engines are writing in there and a tar of a
# live MongoDB is a file that looks like a backup.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/appsmith-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env stacks -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/appsmith-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Appsmith is answering at https://${DOMAIN_HOST}/api/v1/health

	  1. Open https://${DOMAIN_HOST} and create the first account. The welcome
	     form is headed "Almost there". Use exactly
	       ${ADMIN_EMAIL}
	     as the email address: signup is closed for every other address, and
	     that account becomes the instance administrator.
	  2. There is no mail server here, so there is no password reset. Put that
	     password in your password manager as you type it.
	  3. Your encryption keys are in $APP_DIR/.env, mode 600. Read them with
	       sudo grep -E 'ENCRYPTION_PASSWORD|ENCRYPTION_SALT' $APP_DIR/.env
	     and keep them: a restore without them cannot decrypt the datasource
	     credentials you save. They were not printed here.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/appsmith/
	     Restore is: docker compose down, sudo rm -rf $APP_DIR/stacks,
	     sudo tar -xzf the archive -C $APP_DIR, docker compose up -d.

DONE
