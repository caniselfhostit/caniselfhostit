#!/usr/bin/env bash
# Stirling-PDF · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=pdf.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.stirlingpdf.com/Installation/Docker%20Install
#   https://docs.stirlingpdf.com/Configuration/System%20and%20Security/
#   https://caddyserver.com/docs/automatic-https
#
# One secret is generated here, on this machine: the first-login credential for
# the admin account. It is written to /srv/stirling-pdf/.env with mode 600 and it
# is never printed to the terminal. Stirling-PDF forces a change on first login,
# so it is a bootstrap value with a short life.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/stirling-pdf}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_USER="${ADMIN_USER:-admin}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. pdf.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; this install wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; the image alone is several GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image defaults PUID and PGID to 1000 and drops to that user, so /configs is
# owned by 1000 rather than by you.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/config"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# This value has never existed anywhere else: not in the prompt, not in a chat
# window, not in this repository. Read it later with
#   sudo grep SECURITY_INITIALLOGIN_PASSWORD /srv/stirling-pdf/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DISABLE_ADDITIONAL_FEATURES=false
		SECURITY_ENABLELOGIN=true
		SECURITY_INITIALLOGIN_USERNAME=${ADMIN_USER}
		SECURITY_INITIALLOGIN_PASSWORD=$(openssl rand -base64 24)
		SYSTEM_DEFAULTLOCALE=en-GB
		SYSTEM_MAXFILESIZE=100
		SYSTEM_GOOGLEVISIBILITY=false
		METRICS_ENABLED=false
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-stirling-pdf"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8087 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8087 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot is slow. This is a JVM plus LibreOffice, Calibre and Tesseract,
# and the image's own health check allows two minutes before it starts counting.

docker compose pull
docker compose up -d

echo "==> waiting for the container's own health check to go green (up to 5 minutes)"
for _ in $(seq 1 60); do
	state="$(docker inspect --format '{{.State.Health.Status}}' stirling-pdf 2>/dev/null || echo starting)"
	[ "$state" = "healthy" ] && break
	sleep 5
done
[ "${state:-}" = "healthy" ] || die "container health is ${state:-unknown}. Check: docker compose logs --tail 40 stirling-pdf"

# --- 7. Prove it works before claiming it does -------------------------------

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: sudo journalctl -u caddy -n 30"

curl -sSL "https://${DOMAIN_HOST}/" | grep -qi 'stirling' \
	|| die "the page answered 200 but does not mention Stirling. Check: docker compose logs --tail 40 stirling-pdf"

# --- 8. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. The H2 user database captured mid-write is not a backup.

docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/stirling-pdf-$(date +%Y%m%d-%H%M%S).tar.gz" config .env
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	Stirling-PDF is running at https://${DOMAIN_HOST}/

	  1. Sign in as ${ADMIN_USER}. Read the one-time credential with
	     sudo grep SECURITY_INITIALLOGIN_PASSWORD $APP_DIR/.env
	     Stirling-PDF makes you choose a new one immediately. Put that new one
	     in your password manager; the value in .env stops mattering.
	  2. Nothing you upload is kept. Files are processed and returned, and the
	     temporary copy is discarded. This is a workshop, not a document store.
	  3. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
