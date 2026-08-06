#!/usr/bin/env bash
# Vikunja · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=tasks.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://vikunja.io/docs/installing/
#   https://vikunja.io/docs/full-docker-example/
#   https://vikunja.io/docs/config-options/
#   https://vikunja.io/docs/reverse-proxy/
#   https://vikunja.io/docs/what-to-backup/
#
# One secret is generated here, on this machine: the key Vikunja signs session
# tokens with. It goes into /srv/vikunja/.env with mode 600 and is never
# printed. Read it back yourself with
#   sudo grep VIKUNJA_SERVICE_SECRET /srv/vikunja/.env
#
# DOMAIN_HOST also becomes VIKUNJA_SERVICE_PUBLICURL. Vikunja refuses to start
# when that value is empty, so the two are one decision, not two.
#
# There is one pause in this script. Only a human can create the first account,
# and registration stays open until they have.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/vikunja}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. tasks.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The container runs as uid 1000 with no group, so db/ and files/ belong to that
# uid. Chowning them to yourself is the one change that stops it starting.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g "$(id -g)" "$APP_DIR/db" "$APP_DIR/files"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64, so nothing downstream has to escape it. Without a
# value here Vikunja generates a fresh random one at every start, which signs
# out every logged-in session on every restart.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		VIKUNJA_SERVICE_PUBLICURL=https://${DOMAIN_HOST}
		VIKUNJA_SERVICE_TIMEZONE=UTC
		VIKUNJA_SERVICE_ENABLEREGISTRATION=true
		VIKUNJA_SERVICE_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-vikunja"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8097 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8097 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Vikunja creates its own SQLite schema on the first start. The image has no
# shell in it, so `docker compose logs` is the only window into a failure.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/info"
for _ in $(seq 1 20); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/info" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/v1/info answered ${code:-nothing}. Check: docker compose logs --tail 40 vikunja"

curl -sS "https://${DOMAIN_HOST}/api/v1/info" | grep -q '"registration_enabled":true' \
	|| die "the info endpoint answered 200 but registration is not open, so no account can be made. Check step 3."

# --- 7. The first account, which only a human can create ---------------------

cat <<-SETUP

	Open https://${DOMAIN_HOST} now, follow "Create account", and register the
	one account you want. Until you do, anyone who finds this hostname can
	register instead. The next step closes registration and proves it is shut.

SETUP
printf 'Press Return once you are signed in. '
read -r _

sed -i 's/^VIKUNJA_SERVICE_ENABLEREGISTRATION=true$/VIKUNJA_SERVICE_ENABLEREGISTRATION=false/' "$APP_DIR/.env"
docker compose up -d --force-recreate
sleep 15

curl -sS "https://${DOMAIN_HOST}/api/v1/info" | grep -q '"registration_enabled":false' \
	|| die "registration is still open after the restart. Check $APP_DIR/.env and re-run."

# Upstream's register handler returns 404 once registration is off. This is the
# security assert in this script, not a formality.
reg="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "https://${DOMAIN_HOST}/api/v1/register" || true)"
[ "$reg" = "404" ] || die "POST /api/v1/register returned ${reg}, not 404. Registration is still reachable. Stop and investigate."

# --- 8. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup, and
# nothing runs inside this container because there is no shell in it.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/vikunja-${STAMP}.tar.gz" db files .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/vikunja-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Vikunja is running at https://${DOMAIN_HOST}/

	  1. Registration is closed and POST /api/v1/register answers 404. To add
	     another person later, flip VIKUNJA_SERVICE_ENABLEREGISTRATION back to
	     true in $APP_DIR/.env, run docker compose up -d --force-recreate,
	     let them register, then set it to false and recreate again.
	  2. Nothing sends mail here. Upstream's reminder job only delivers over
	     mail or a webhook, so a due date is something you see when you open
	     the app, not something that arrives. If you came from Todoist, that
	     is the habit that does not survive the move.
	  3. Your signing key is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep VIKUNJA_SERVICE_SECRET $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  4. First backup written to $APP_DIR/backups: one archive holding
	     db/, files/, .env, compose.yml and Caddyfile. It is on the same disk
	     as the data, which is not a backup. Copy it somewhere else tonight.

DONE
