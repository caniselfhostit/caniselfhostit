#!/usr/bin/env bash
# Kavita · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=books.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://wiki.kavitareader.com/installation/docker/
#   https://wiki.kavitareader.com/installation/docker/dockerhub/
#   https://wiki.kavitareader.com/installation/remote-access/caddy-example/
#   https://wiki.kavitareader.com/guides/admin-settings/libraries/
#
# No secret is generated here and no .env file is written. On first start
# Kavita draws 256 random bytes for the key that signs user sessions and writes
# it into /srv/kavita/config/appsettings.json itself, which the backup at the
# end of this script already covers.
#
# This script does not create your Kavita account. Only a browser can, and
# until you do, Kavita answers every visitor with its Register form and the
# first person to fill it in becomes the administrator. The summary at the end
# tells you to go and do it now, and gives you the command that proves the form
# is shut.
#
# It does not add your library either. Kavita scans no folder it has not been
# told about, so copying books into books/ does nothing until you add a library
# in the web UI. The summary says how.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/kavita}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. books.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v curl >/dev/null 2>&1 || die "curl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; the first library scan wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB before any books"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# config stays root-owned at mode 700: upstream took the PUID and PGID handling
# out of its container entrypoint, so Kavita runs as root and writes its
# database as root, and nothing else on this box needs to read the user table.
# books is yours, so you can copy your library in.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/config"
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/books"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-kavita"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8146 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8146 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 kavita"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q 'Ok' \
	|| die "/api/health answered 200 without Ok. Check: docker compose logs --tail 40 kavita"

# Nobody has claimed the admin account yet. That is expected at this point and
# it is also the thing you have to go and fix in a browser.
state="$(curl -sS "https://${DOMAIN_HOST}/api/admin/exists" || true)"
[ "$state" = "false" ] || die "/api/admin/exists reported ${state:-nothing}, not false. Stop and investigate."

# --- 6. The first backup, before day one ends --------------------------------
#
# The database, the settings file holding the session key, the compose file and
# the live Caddy config. Not the books: those are your library, and they belong
# in the backup that already protects the machine you copied them from. The
# cache and temp folders are skipped because Kavita rebuilds both.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar --exclude='config/cache' --exclude='config/cache-long' --exclude='config/temp' \
	-czf "$APP_DIR/backups/kavita-config-${STAMP}.tar.gz" \
	-C "$APP_DIR" config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/kavita-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Kavita is answering at https://${DOMAIN_HOST}/api/health

	  1. Do this first, now, before anything else. Open https://${DOMAIN_HOST}
	     and create your account on the screen that reads "Register". Until
	     you do, the first person to load that hostname becomes the
	     administrator of this server. Then prove the form is shut:
	       curl -sS https://${DOMAIN_HOST}/api/admin/exists
	     That must print true.
	  2. Copy your books into $APP_DIR/books, from your own machine. Upstream
	     requires one folder per series and no files loose at the top:
	       rsync -av --info=progress2 ~/Books/ vps:$APP_DIR/books/
	     Then add the library in the web UI: Libraries, Add Library, type
	     Book, folder /books. Nothing is scanned until you do. Watch what the
	     scanner found:
	       cd $APP_DIR && docker compose logs kavita | grep -F '[ScannerService] Found' | tail -1
	  3. That folder is mounted read-only. Kavita reads filenames and in-file
	     metadata and writes nothing back into your library, which is the
	     point.
	  4. First backup written to $APP_DIR/backups. It was taken before your
	     account existed, so it holds an empty user table: once you have
	     registered and the first scan has run, take it again with the same
	     tar command from this script. Kavita's own backup task also writes
	     into config/backups on its own schedule, which is inside the same
	     directory this archive covers. All of it sits on the same disk as
	     the data, which is not a backup. Copy the fresh archive somewhere
	     else tonight.

DONE
