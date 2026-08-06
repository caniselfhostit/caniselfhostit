#!/usr/bin/env bash
# Navidrome · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=music.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.navidrome.org/docs/installation/docker/
#   https://www.navidrome.org/docs/usage/configuration/options/
#   https://www.navidrome.org/docs/usage/admin/security/
#   https://www.navidrome.org/docs/usage/admin/backup/
#   https://www.navidrome.org/docs/getting-started/
#
# One secret is generated here, on this machine: ND_PASSWORDENCRYPTIONKEY, the
# passphrase Navidrome encrypts stored passwords with. It goes into
# /srv/navidrome/.env with mode 600 and is never printed. Upstream is explicit
# that it is written once: changing it later locks every account out.
#
# This script does not create your Navidrome account. Only a browser can, and
# until you do, whoever loads the hostname first becomes the administrator. The
# summary at the end tells you to go and do it now, and gives you the one
# command that proves the window is shut.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/navidrome}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. music.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB before any music"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data and backups belong to uid 1000, the uid the container runs as. music
# stays yours so you can copy your library into it, and is world-readable so
# the container can read it without owning it.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/data" "$APP_DIR/backups"
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/music"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: Docker Compose also reads this file for variable
# interpolation, and a `$` in the value would be expanded. Read it later with
#   sudo grep ND_PASSWORDENCRYPTIONKEY /srv/navidrome/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		ND_PASSWORDENCRYPTIONKEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-navidrome"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8108 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8108 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ping"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/ping" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/ping answered ${code:-nothing}. Check: docker compose logs --tail 40 navidrome"

body="$(curl -sS "https://${DOMAIN_HOST}/ping" || true)"
[ "$body" = "." ] || die "/ping answered 200 with '${body}' instead of a single dot. Stop and investigate."

# Nobody has claimed the administrator account yet. That is expected at this
# point and it is also the thing you have to go and fix in a browser.
state="$(curl -sS "https://${DOMAIN_HOST}/app/" | tr -d '\\' | grep -o '"firstTime":[a-z]*' || true)"
[ "$state" = '"firstTime":true' ] || die "the web app reported ${state:-nothing}, not \"firstTime\":true. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------
#
# The database, the encryption key, the compose file and the live Caddy config.
# Not the music: that is your library, and it belongs in the backup that already
# protects the machine you copied it from.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/navidrome-config-${STAMP}.tar.gz" -C "$APP_DIR" data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/navidrome-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Navidrome is answering at https://${DOMAIN_HOST}/ping

	  1. Do this first, now, before anything else. Open https://${DOMAIN_HOST}
	     and create your account on the screen that reads "Thanks for
	     installing Navidrome!". Until you do, the first person to load that
	     hostname becomes the administrator of this server. Then prove the
	     window is shut:
	       curl -sS https://${DOMAIN_HOST}/app/ | tr -d '\\\\' | grep -o '"firstTime":[a-z]*'
	     That must print "firstTime":false.
	  2. Copy your music into $APP_DIR/music, from your own machine:
	       rsync -av --info=progress2 ~/Music/ vps:$APP_DIR/music/
	     Then count what Navidrome found:
	       cd $APP_DIR && docker compose exec -T navidrome sqlite3 /data/navidrome.db "select count(*) from media_file"
	     If it prints 0, run: sudo chmod -R a+rX $APP_DIR/music
	  3. Your password encryption key is in $APP_DIR/.env, mode 600. Read it
	     with
	       sudo grep ND_PASSWORDENCRYPTIONKEY $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and
	     upstream will not let you change it later.
	  4. First backup written to $APP_DIR/backups. A nightly database snapshot
	     lands there at 04:00 as well. Both sit on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight.

DONE
