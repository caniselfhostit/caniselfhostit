#!/usr/bin/env bash
# Jellyfin · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=media.example.com JELLYFIN_MEDIA_PATH=/mnt/media ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://jellyfin.org/docs/general/installation/container
#   https://jellyfin.org/docs/general/post-install/setup-wizard/
#   https://jellyfin.org/docs/general/administration/backup-and-restore
#   https://jellyfin.org/docs/general/networking/caddy
#
# No application secret is generated here. The first credential is the admin
# account created in the setup wizard. Between first start and that account,
# anyone who can reach the hostname may finish setup first.
#
# Media is a bind mount of JELLYFIN_MEDIA_PATH (required). Config and cache are
# the backed-up state; media files are not.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/jellyfin}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
JELLYFIN_MEDIA_PATH="${JELLYFIN_MEDIA_PATH:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. media.example.com"
[ -n "$JELLYFIN_MEDIA_PATH" ] || die "set JELLYFIN_MEDIA_PATH to an absolute path of a media library you own, e.g. /mnt/media"
[ -d "$JELLYFIN_MEDIA_PATH" ] || die "JELLYFIN_MEDIA_PATH=$JELLYFIN_MEDIA_PATH is not a directory"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; this install wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Config and cache are writable state. Media is the user's path, never a fresh
# root-owned empty tree invented by this script.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" \
	"$APP_DIR" "$APP_DIR/backups" "$APP_DIR/config" "$APP_DIR/cache"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

umask 077
printf 'JELLYFIN_MEDIA_PATH=%s\n' "$JELLYFIN_MEDIA_PATH" > "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"
umask 022

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-jellyfin"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8204 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8204 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/System/Info/Public"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/System/Info/Public" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/System/Info/Public answered ${code:-nothing}. Check: docker compose logs --tail 40 jellyfin"

curl -sS "https://${DOMAIN_HOST}/System/Info/Public" | grep -qi 'jellyfin' \
	|| die "public system info does not name Jellyfin"

wizard="$(curl -sS "https://${DOMAIN_HOST}/System/Info/Public" | grep -o '"StartupWizardCompleted":[^,]*' || true)"
echo "==> $wizard (false until you finish the setup wizard in a browser)"

# --- 6. The first backup (config + cache only; media stays outside) ----------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/jellyfin-${STAMP}.tar.gz" \
	-C "$APP_DIR" config cache compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/jellyfin-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Jellyfin is answering at https://${DOMAIN_HOST}

	  1. Open that URL now and finish the setup wizard. Create the admin account
	     immediately: until StartupWizardCompleted is true, anyone who reaches
	     the hostname can claim the server.
	  2. In the wizard, add a library that points at /media inside the container
	     (that is ${JELLYFIN_MEDIA_PATH} on the host, mounted read-only).
	  3. After the wizard, check:
	       curl -sS https://${DOMAIN_HOST}/System/Info/Public | grep StartupWizardCompleted
	     It should print true.
	  4. First backup written to $APP_DIR/backups (config, cache, compose, .env,
	     live Caddyfile). Media files are not in it. Copy the archive off this
	     disk tonight.
	  5. Remote streams cost egress on this VPS. A home box on the same LAN as
	     the library is the usual shape for heavy playback.
	  6. NOT YET VERIFIED on a clean harness machine.

DONE
