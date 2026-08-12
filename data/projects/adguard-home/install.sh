#!/usr/bin/env bash
# AdGuard Home · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=adguard.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/AdguardTeam/AdGuardHome/wiki/Docker
#   https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration
#
# This VPS path publishes the admin UI behind Caddy only. It does NOT open DNS
# port 53 to the world. Household DNS needs a LAN install or a VPN back to a
# resolver you control. During the first-run wizard, keep the web UI on port
# 3000 so the 8201:3000 mapping continues to work after setup.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/adguard-home}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. adguard.example.com"
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
# work/ and conf/ are the real state mounts. There is no data/ directory.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/work" "$APP_DIR/conf"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-adguard-home"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: Caddy only. Never open 53 on this VPS path. -------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8201 and 53 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for wizard or UI on https://${DOMAIN_HOST}/"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	case "$code" in 200|301|302|303|307|308) break ;; esac
	sleep 5
done
[ -n "${code:-}" ] && [ "$code" != "000" ] || die "nothing answered at https://${DOMAIN_HOST}/. Check: docker compose logs --tail 40 adguard-home"

# Port 53 must not be listening on the public interfaces of this host.
if command -v ss >/dev/null 2>&1; then
	if ss -lunpt 2>/dev/null | grep -E ':53\b' | grep -vq '127.0.0.1'; then
		die "something is listening on port 53 beyond loopback. This VPS path must not be an open resolver."
	fi
fi

# --- 6. First backup of whatever state exists (pre or post wizard) -----------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/adguard-home-${STAMP}.tar.gz" -C "$APP_DIR" work conf compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/adguard-home-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	AdGuard Home admin UI should be reachable at https://${DOMAIN_HOST}/

	  1. Open the URL and finish the first-run wizard if it appears. When the
	     wizard asks for the Admin Web Interface port, keep it at 3000. Do not
	     move the UI to port 80: this compose only publishes 8201:3000, so a UI
	     on 80 is unreachable through Caddy.
	  2. Create the admin account in the wizard. After the wizard, sign in and
	     confirm the dashboard loads. The admin password hash is stored in
	     conf/AdGuardHome.yaml (and only there until you change it).
	  3. This VPS is NOT your household DNS yet. Port 53 is not published and
	     must not be opened to the world. For LAN DNS, install on a home box
	     (local path) or reach this UI over a VPN and run DNS where the LAN is.
	  4. First backup written to $APP_DIR/backups (work/, conf/, compose, live
	     Caddyfile). Copy it off this disk tonight. A later backup after the
	     wizard completes is what actually holds your blocklists and admin hash.

DONE
