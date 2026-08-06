#!/usr/bin/env bash
# Audiobookshelf · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=books.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.audiobookshelf.org/docs/documentation/install/docker
#   https://www.audiobookshelf.org/docs/documentation/install/configuration
#   https://www.audiobookshelf.org/docs/documentation/install/reverse-proxy/caddy
#   https://www.audiobookshelf.org/docs/documentation/server-management/backups
#
# No secret is generated here and no .env file is written. Upstream creates the
# key that signs sessions on first start and keeps it in the database under
# /srv/audiobookshelf/config, which the backup at the end of this script
# already covers.
#
# This script does not create your Audiobookshelf account. Only a browser can,
# and until you do, whoever loads the hostname first becomes the root user. The
# summary at the end tells you to go and do it now, and gives you the one
# command that proves the setup screen is shut.
#
# It does not add your library either. Audiobookshelf scans no folder it has
# not been told about, so copying audio into audiobooks/ does nothing until you
# add a library in the web UI. The summary says how.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/audiobookshelf}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. books.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v curl >/dev/null 2>&1 || die "curl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB before any audio"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# config and metadata stay root-owned at mode 700: upstream states that
# Audiobookshelf does not read PUID or PGID, so the container runs as root and
# writes its database as root, and nothing else on this box needs to read it.
# audiobooks and podcasts are yours, so you can copy your library in.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/config" "$APP_DIR/metadata"
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/audiobooks" "$APP_DIR/podcasts"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-audiobookshelf"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8125 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8125 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthcheck"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthcheck" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/healthcheck answered ${code:-nothing}. Check: docker compose logs --tail 40 audiobookshelf"

# Nobody has claimed the root account yet. That is expected at this point and
# it is also the thing you have to go and fix in a browser.
state="$(curl -sS "https://${DOMAIN_HOST}/status" | grep -o '"isInit":[a-z]*' || true)"
[ "$state" = '"isInit":false' ] || die "/status reported ${state:-nothing}, not \"isInit\":false. Stop and investigate."

# --- 6. The first backup, before day one ends --------------------------------
#
# The database, the compose file and the live Caddy config. Not the audio: that
# is your library, and it belongs in the backup that already protects the
# machine you copied it from. Upstream's own backups exclude media too.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/audiobookshelf-config-${STAMP}.tar.gz" -C "$APP_DIR" config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/audiobookshelf-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Audiobookshelf is answering at https://${DOMAIN_HOST}/healthcheck

	  1. Do this first, now, before anything else. Open https://${DOMAIN_HOST}
	     and create your account on the screen that reads "Initial Server
	     Setup". Until you do, the first person to load that hostname becomes
	     the root user of this server. Choose a real one, because the form
	     will accept an empty password behind a confirmation dialog. Then
	     prove the setup screen is shut:
	       curl -sS https://${DOMAIN_HOST}/status | grep -o '"isInit":[a-z]*'
	     That must print "isInit":true.
	  2. Copy your audiobooks into $APP_DIR/audiobooks, from your own machine.
	     Upstream expects one folder per book, {Author}/{Book}:
	       rsync -av --info=progress2 ~/Audiobooks/ vps:$APP_DIR/audiobooks/
	     Then add the library in the web UI: Libraries, Add Library, media
	     type Books, folder /audiobooks. Nothing is scanned until you do.
	     Watch what the scanner found:
	       cd $APP_DIR && docker compose logs audiobookshelf | grep -F 'Library scan' | tail -2
	  3. That folder is mounted read-only, so the upload button in the UI will
	     not write to it. Nothing else in this install needs write access to
	     your library, which is the point.
	  4. First backup written to $APP_DIR/backups. The scheduled backup inside
	     Audiobookshelf is off until you turn it on, in Settings, Backups; it
	     is already pointed at this folder. Both sit on the same disk as the
	     data, which is not a backup. Copy them somewhere else tonight.

DONE
