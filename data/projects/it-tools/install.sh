#!/usr/bin/env bash
# IT Tools · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=tools.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/CorentinTh/it-tools#self-host
#
# No secret is generated. There are no accounts, no registration form and no
# first-run wizard. The page is public by design: anyone who can reach the
# hostname can use every tool. Put Caddy basic_auth in front if that is not
# what you want. There is no application data directory; backup is compose
# plus the live Caddyfile.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/it-tools}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. tools.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 256 ] || die "only ${avail_mb} MB of RAM available; this install wants 256 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 2 ] || die "only ${avail_gb} GB free on /srv; this install wants 2 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No data/ directory: the container is stateless static UI.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-it-tools"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports ----------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8209 stays closed"
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
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs --tail 40 it-tools"

curl -sSL "https://${DOMAIN_HOST}/" | grep -qiE 'it-tools|IT Tools|token|encode|hash' \
	|| die "the page at https://${DOMAIN_HOST}/ does not look like IT Tools"

# --- 6. Backup (compose + live Caddyfile only; no app state) -----------------

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/it-tools-${STAMP}.tar.gz" \
	-C "$APP_DIR" compose.yml \
	-C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/it-tools-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	IT Tools is answering at https://${DOMAIN_HOST}

	  1. That page is public. There is no login and no account. Anyone who can
	     reach the hostname can use every tool. Open it in a private window and
	     read it as a stranger would. Caddy basic_auth is the opt-in if you want
	     a password in front.
	  2. There is no application data directory. The backup is compose.yml plus
	     the live Caddyfile only.
	  3. Pinned image tag 2024.10.22-7ca5933 was published 2024-10-22 (about 21
	     months before this install's 2026-08-07 check). See releases before
	     assuming a newer stable tag exists.
	  4. Copy $APP_DIR/backups off this disk if you care about the Caddy site
	     block; the tools themselves are the image.
	  5. NOT YET VERIFIED on a clean harness machine.

DONE
