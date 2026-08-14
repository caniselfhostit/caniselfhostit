#!/usr/bin/env bash
# Super Productivity · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=tasks.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/super-productivity/super-productivity/blob/v18.19.0/docs/wiki/2.13-Run-with-Docker.md
#
# No secret is generated and no .env is written. There are no accounts, no
# registration form and no first-run wizard, because there is no server-side
# store to have an account in: upstream states that data is stored in the
# browser and the container provides no persistent storage. The page is public
# by design, and a stranger who loads it gets an empty task list in their own
# browser rather than a window into yours. Caddy basic_auth is the opt-in if
# you would rather the URL were not world-readable.
#
# There is no application data directory. This script's backup is compose.yml
# plus the live Caddyfile. YOUR backup is the app's own Export data file, and
# the summary at the end tells you where to click for it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/super-productivity}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. tasks.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 256 ] || die "only ${avail_mb} MB of RAM available; this install wants 256 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 2 ] || die "only ${avail_gb} GB free on /srv; this install wants 2 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')" || resolved=""
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No data/ directory. The container mounts nothing and writes nothing you
# would want back.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-super-productivity"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports ----------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8199 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/")" || code=""
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs --tail 40 super-productivity"

# --- 6. Asserts, with their evidence printed ---------------------------------

title_hits="$(curl -sSL "https://${DOMAIN_HOST}/" | grep -c '<title>Super Productivity</title>')" || title_hits=0
echo "==> title marker count: ${title_hits}"
[ "$title_hits" -ge 1 ] || die "the page at https://${DOMAIN_HOST}/ does not look like Super Productivity"

echo "==> served sync defaults:"
override="$(curl -sS "https://${DOMAIN_HOST}/assets/sync-config-default-override.json")"
printf '%s\n' "$override"
leaks="$(printf '%s' "$override" | grep -ciE 'password|userName|baseUrl|syncFolderPath')" || leaks=0
echo "==> credential-shaped keys in that file: ${leaks}"
[ "$leaks" -eq 0 ] || die "the served sync defaults name a server or an account. This install sets no WEBDAV_ variables, so that file should carry nothing but its comment."

dav_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/webdav/")" || dav_code=""
echo "==> /webdav/ answered: ${dav_code}"
[ "$dav_code" = "404" ] || die "/webdav/ answered ${dav_code:-nothing}; with WEBDAV_BACKEND unset the image's proxy route must answer 404"

# --- 7. Backup (compose + live Caddyfile; there is no app state on this box) --

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/super-productivity-${STAMP}.tar.gz" \
	-C "$APP_DIR" compose.yml \
	-C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/super-productivity-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Super Productivity is answering at https://${DOMAIN_HOST}

	  1. Open it and add one task. That task is now in this browser and nowhere
	     else. The server holds nothing, which is why the archive above is two
	     files of configuration and not a database.
	  2. Take your real backup now, in the app: Settings, the Sync & Backup tab,
	     then Export data. That downloads one plaintext JSON file holding tasks,
	     projects, tags, time tracking, notes and archives. Import in the same
	     place puts it back. Keep the file somewhere that is not this laptop,
	     and treat it as private: it is not encrypted and it can carry the API
	     credentials of any issue provider you connect later.
	  3. That page is public. There is no login, because there is no account.
	     Anyone who reaches the hostname gets their own empty list, not yours.
	     Caddy basic_auth is the opt-in if you want a password in front.
	  4. Cross-device sync is not configured and is not one setting away. Read
	     block 8 of prompt.md before you try: upstream says browser WebDAV sync
	     is likely to fail on CORS, and the image's own same-origin workaround
	     caps uploads at 1 MB and sends no TLS server name upstream.
	  5. Copy $APP_DIR/backups off this disk, and copy the exported JSON off it
	     too. NOT YET VERIFIED on a clean harness machine.

DONE
