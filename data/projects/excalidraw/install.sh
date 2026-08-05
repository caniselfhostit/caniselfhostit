#!/usr/bin/env bash
# Excalidraw · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=draw.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://hub.docker.com/r/excalidraw/excalidraw
#   https://docs.excalidraw.com/docs/introduction/development
#   https://caddyserver.com/docs/automatic-https
#
# There is nothing to generate here. Excalidraw has no accounts, no database and
# no server side documents, so this install creates no secrets at all.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/excalidraw}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. draw.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 256 ] || die "only ${avail_mb} MB of RAM available; this install wants 256 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 2 ] || die "only ${avail_gb} GB free on /srv; this install wants 2 GB"

# The A record has to exist before Caddy asks for a certificate, or the request
# fails and you learn that by burning a Let's Encrypt rate-limit slot.
resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"
cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-excalidraw"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8083 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8083 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

# --- 6. Prove it works before claiming it does -------------------------------

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs excalidraw"

curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Excalidraw' \
	|| die "the page answered 200 but does not mention Excalidraw. Check: docker compose logs excalidraw"

# --- 7. The first backup, before day one ends --------------------------------
#
# What is on this server is the configuration, not the drawings. The drawings
# are in the browser that made them, which is why step 8 of prompt.md tells you
# to export one and copy it off the box as well.

tar -czf "$APP_DIR/backups/excalidraw-config-$(date +%Y%m%d-%H%M%S).tar.gz" \
	-C "$APP_DIR" compose.yml Caddyfile
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	Excalidraw is running at https://${DOMAIN_HOST}/

	  1. Open it. You get a blank canvas and a toolbar. There is no login,
	     because there are no accounts.
	  2. Anyone who reaches that hostname gets their own blank canvas. They
	     cannot see yours: your drawing is in your browser, not on this server.
	  3. Draw something, then use the app's export to save a .excalidraw file
	     and copy it off this machine. That file is your only real backup.
	  4. Config backup written to $APP_DIR/backups. It is on the same disk as
	     the thing it backs up, which is not a backup. Copy it somewhere else.

DONE
