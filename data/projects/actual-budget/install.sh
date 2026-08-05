#!/usr/bin/env bash
# Actual Budget · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=budget.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://actualbudget.org/docs/install/docker
#   https://actualbudget.org/docs/config/
#   https://caddyserver.com/docs/automatic-https
#
# Nothing is generated here. Actual has one credential, the server password, and
# you choose it in a browser at step 7. There is no .env file in this install.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/actual-budget}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. budget.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image creates an actual account with uid 1001 and runs as it.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1001 -g 1001 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-actual-budget"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8090 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8090 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it and prove it works ------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 30 actual"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q 'UP' \
	|| die "/health answered 200 but did not report UP. Check: docker compose logs --tail 30 actual"

curl -sS "https://${DOMAIN_HOST}/account/needs-bootstrap" | grep -q '"bootstrapped":false' \
	|| echo "==> this server already has a password set; skipping the bootstrap prompt"

# --- 6. Set the one credential this install has ------------------------------

cat <<-BOOTSTRAP

	Open https://${DOMAIN_HOST} now and choose the server password. Until you do,
	whoever loads that page first gets to choose it instead, and that one
	password guards every budget file on this server.

BOOTSTRAP
printf 'Press Return once you have set it. '
read -r _

curl -sS "https://${DOMAIN_HOST}/account/needs-bootstrap" | grep -q '"bootstrapped":true' \
	|| die "the server still reports bootstrapped:false. Set the password before going on."

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/actual-budget-$(date +%Y%m%d-%H%M%S).tar.gz" data
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	Actual Budget is running at https://${DOMAIN_HOST}/

	  1. data/ is the whole install. server-files/account.sqlite holds the
	     password hash, user-files holds the budgets. There is no .env here.
	  2. Actual does not talk to banks by itself. GoCardless and SimpleFIN are
	     separate signups with their own credentials, and in the United States
	     the usable one costs money. Find that out now, not after you migrate.
	  3. Export a zip of your budget from inside the app once a month and keep
	     it somewhere else. It is readable without a server, which is more than
	     any archive on this box can say.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
