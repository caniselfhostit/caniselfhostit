#!/usr/bin/env bash
# Uptime Kuma · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=status.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/louislam/uptime-kuma/blob/master/compose.yaml
#   https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install
#   https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy
#   https://caddyserver.com/docs/automatic-https
#
# Nothing is generated here. Uptime Kuma's only credential is the administrator
# account, and you create it in a browser at step 6. There is no .env file.
#
# Caddy runs under systemd on this host, installed by Prompt Zero. This script
# appends one site block to /etc/caddy/Caddyfile and starts no proxy container.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/uptime-kuma}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. status.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

echo "==> reminder: a monitor on this box cannot tell you this box is down."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image runs as the node user, uid 1000. db-config.json is written before
# the first boot because it is what picks the database: with it present, Uptime
# Kuma uses SQLite and skips its database setup screen.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/data"
if [ ! -f "$APP_DIR/data/db-config.json" ]; then
	printf '{\n    "type": "sqlite"\n}\n' | sudo tee "$APP_DIR/data/db-config.json" >/dev/null
	sudo chown 1000:1000 "$APP_DIR/data/db-config.json"
fi
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-uptime-kuma"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8091 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8091 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it and prove it works ------------------------------------------
#
# The image's health check allows a three-minute start period.

docker compose pull
docker compose up -d

echo "==> waiting for the container's own health check to go green"
for _ in $(seq 1 48); do
	state="$(docker inspect --format '{{.State.Health.Status}}' uptime-kuma 2>/dev/null || echo starting)"
	[ "$state" = "healthy" ] && break
	sleep 5
done
[ "${state:-}" = "healthy" ] || die "container health is ${state:-unknown}. Check: docker compose logs --tail 40 uptime-kuma"

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: sudo journalctl -u caddy -n 30"

curl -sS "https://${DOMAIN_HOST}/setup-database-info" | grep -q '"needSetup":false' \
	|| die "the database setup screen is still running, so data/db-config.json did not take. Check step 2."

curl -sSL "https://${DOMAIN_HOST}/" | grep -qi 'uptime kuma' \
	|| die "the page answered 200 but does not mention Uptime Kuma. Check: docker compose logs --tail 40 uptime-kuma"

# --- 6. Create the administrator account -------------------------------------

cat <<-SETUP

	Open https://${DOMAIN_HOST} now and create the administrator account. Until
	you do, whoever loads that page first can create it instead. Then reload the
	page in a private window: you should get a sign-in form and no
	create-account fields.

SETUP
printf 'Press Return once you are signed in and the private window shows a sign-in form. '
read -r _

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/uptime-kuma-$(date +%Y%m%d-%H%M%S).tar.gz" data
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	Uptime Kuma is running at https://${DOMAIN_HOST}/

	  1. Add a monitor, then add a second one pointed at a hostname that does
	     not exist, and wait for it to go red. If no alert reaches your phone,
	     your notification channel is decoration. Test it today.
	  2. Point one free external check at ${DOMAIN_HOST} itself. This server
	     cannot tell you it is down.
	  3. Heartbeat history is kept forever by default. On a small disk that is
	     what fills it; the retention setting in the interface is the lever.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
