#!/usr/bin/env bash
# Baserow · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=base.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://baserow.io/docs/installation%2Finstall-with-docker
#   https://baserow.io/docs/installation%2Fconfiguration
#   https://baserow.io/docs/installation%2Finstall-on-aws
#   https://baserow.io/docs/installation%2Fsupported
#
# Two secrets are generated here, on this machine: the Django secret key and the
# JWT signing key. Both go into /srv/baserow/.env with mode 600 and neither is
# ever printed. The image would invent its own pair inside the data volume if
# these were absent; keeping them in .env is what lets one archive carry both.
#
# DOMAIN_HOST is also BASEROW_PUBLIC_URL. The Caddy inside the container matches
# the Host header against it, so the two have to stay the same string.
#
# This script leaves two things for a human: creating the first account, which
# becomes the administrator, and turning off new signups afterwards.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/baserow}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. base.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; the all-in-one image wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data stays owned by root: the container starts as root, chowns it to uid 9999
# and only then drops privileges, and the PostgreSQL inside it refuses to
# initialise in a directory somebody else already owns.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64: both are read by a shell before Django sees them and
# neither wants escaping. Read them later with
#   sudo grep -E 'SECRET_KEY|SIGNING_KEY' /srv/baserow/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASEROW_PUBLIC_URL=https://${DOMAIN_HOST}
		SECRET_KEY=$(openssl rand -hex 32)
		BASEROW_JWT_SIGNING_KEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-baserow"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8175 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8175, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot initialises a PostgreSQL cluster, runs every Django migration
# and imports the built-in templates. Upstream's deployment guide asks for a
# 900-second grace period on a first start; this loop allows exactly that.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/_health/ (up to 15 minutes)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/_health/" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/_health/ answered ${code:-nothing}. Check: docker compose logs --tail 60 baserow"

curl -sS "https://${DOMAIN_HOST}/api/_health/" | grep -q '^OK$' \
	|| die "health answered 200 without the body OK. Check: docker compose logs --tail 60 baserow"

# No account exists yet, and the instance says so. A false here on a fresh
# install means somebody else has already claimed the administrator account.
curl -sS "https://${DOMAIN_HOST}/api/settings/" | grep -q '"show_admin_signup_page":true' \
	|| die "this instance already has an account. Stop, run: docker compose down && sudo rm -rf ${APP_DIR}/data, then rerun this script."

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped, because a PostgreSQL cluster and a Redis are writing in there and a
# tar of a live database is a file that looks like a backup.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/baserow-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/baserow-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Baserow is answering at https://${DOMAIN_HOST}/api/_health/

	  1. Open https://${DOMAIN_HOST} and create the first account now. The form
	     is headed "Welcome to Baserow!" over "Please fill the form below to
	     create the admin user." That account is given staff rights, which is
	     what makes it the administrator, and until it exists anyone reaching
	     this hostname can claim it.
	  2. Then open https://${DOMAIN_HOST}/admin/settings and turn off
	     "Allow creating new accounts". Confirm from here with
	       curl -sS https://${DOMAIN_HOST}/api/settings/
	     which should now report allow_new_signups false. Leaving it on leaves
	     signups open to every visitor.
	  3. There is no mail server here, so there is no password reset. Put that
	     password in your password manager as you type it.
	  4. Your two keys are in $APP_DIR/.env, mode 600. Read them with
	       sudo grep -E 'SECRET_KEY|SIGNING_KEY' $APP_DIR/.env
	     and keep them: a restore without them signs everybody out. They were
	     not printed here.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/baserow/
	     Restore is: docker compose down, sudo rm -rf $APP_DIR/data,
	     sudo tar -xzf the archive -C $APP_DIR, docker compose up -d.

DONE
