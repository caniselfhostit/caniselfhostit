#!/usr/bin/env bash
# Netdata · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=metrics.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://learn.netdata.cloud/docs/installing/docker
#   https://learn.netdata.cloud/docs/netdata-agent/configuration/securing-agents/running-the-agent-behind-a-reverse-proxy/caddy
#   https://github.com/netdata/netdata/blob/v2.10.4/README.md
#   https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# One secret is generated: the Caddy basic_auth password. The Netdata agent has
# no setup wizard on this path. Agent is GPL-3.0-or-later; UI is closed-source
# NCUL1. Capabilities: SYS_PTRACE, SYS_ADMIN, apparmor:unconfined.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/netdata}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. metrics.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

caddy_ver="$(caddy version | head -1 | cut -d' ' -f1 | sed 's/^v//')"
caddy_major="${caddy_ver%%.*}"
caddy_rest="${caddy_ver#*.}"
caddy_minor="${caddy_rest%%.*}"
if [ "$caddy_major" -lt 2 ] || { [ "$caddy_major" -eq 2 ] && [ "$caddy_minor" -lt 8 ]; }; then
	die "caddy ${caddy_ver} predates 2.8, where the basic_auth directive this install uses arrived"
fi

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Layout ---------------------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" \
	"$APP_DIR" "$APP_DIR/backups" "$APP_DIR/config" "$APP_DIR/lib" "$APP_DIR/cache"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Password for Caddy basic_auth ----------------------------------------

if [ ! -f "$APP_DIR/dashboard-password" ]; then
	umask 077
	openssl rand -hex 24 > "$APP_DIR/dashboard-password"
	chmod 600 "$APP_DIR/dashboard-password"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy auth conf + site block -----------------------------------------

umask 077
caddy hash-password < "$APP_DIR/dashboard-password" > "$APP_DIR/auth.hash"
printf 'basic_auth {\n\tnetdata %s\n}\n' "$(cat "$APP_DIR/auth.hash")" > "$APP_DIR/auth.conf"
umask 022
sudo install -m 640 -o root -g caddy "$APP_DIR/auth.conf" /etc/caddy/netdata-auth.conf
rm -f "$APP_DIR/auth.hash" "$APP_DIR/auth.conf"

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-netdata"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Firewall -------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8207 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start and assert -----------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8207/api/v1/info"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8207/api/v1/info" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "loopback /api/v1/info answered ${code:-nothing}. Check: docker compose logs --tail 40 netdata"

unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/info" || true)"
[ "$unauth" = "401" ] || die "unauthenticated public request returned ${unauth}, not 401"

auth="$(curl -sS -o /dev/null -w '%{http_code}' -u "netdata:$(cat "$APP_DIR/dashboard-password")" "https://${DOMAIN_HOST}/api/v1/info" || true)"
[ "$auth" = "200" ] || die "authenticated public request returned ${auth}, not 200"

# --- 7. First backup ---------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/netdata-${STAMP}.tar.gz" \
	-C "$APP_DIR" config lib cache compose.yml dashboard-password \
	-C /etc/caddy Caddyfile netdata-auth.conf
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/netdata-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Netdata is answering at https://${DOMAIN_HOST}

	  1. Login username is netdata. Read the dashboard credential with:
	       sudo cat ${APP_DIR}/dashboard-password
	     There is no Netdata-native setup wizard on this path.
	  2. Unauthenticated requests return 401 (asserted above).
	  3. License: agent GPL-3.0-or-later; dashboard UI closed-source NCUL1.
	  4. Capabilities: SYS_PTRACE, SYS_ADMIN, apparmor:unconfined (host metrics).
	  5. First backup at ${APP_DIR}/backups (config, lib, cache, password, Caddy).
	     Copy it off this disk tonight.
	  6. NOT YET VERIFIED on a clean harness machine.

DONE
