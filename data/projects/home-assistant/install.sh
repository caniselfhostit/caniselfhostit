#!/usr/bin/env bash
# Home Assistant · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=home.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.home-assistant.io/installation/linux/
#   https://www.home-assistant.io/integrations/http/
#   https://www.home-assistant.io/docs/configuration/remote/
#
# No secret is generated here and there is no .env file. Home Assistant's only
# credential is the owner account, and a human creates it in a browser once this
# script finishes. Until they do, the onboarding form is open to whoever loads
# the hostname first, so do not walk away between the last line of output and
# that browser tab.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/home-assistant}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. home.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; the first boot installs several dozen Python packages and wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Home Assistant writes its own configuration.yaml on the first start, and this
# install cannot let it: the file has to name the reverse proxy before the first
# request arrives, because a proxied request is rejected with 400 until the
# proxy is trusted. The three include targets are created empty because a
# missing include stops the container from starting.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/config" "$APP_DIR/config/themes"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

if ! sudo test -f "$APP_DIR/config/configuration.yaml"; then
	sudo tee "$APP_DIR/config/configuration.yaml" >/dev/null <<-'HACONF'
		# Loads default set of integrations. Do not remove.
		default_config:

		# Load frontend themes from the themes folder
		frontend:
		  themes: !include_dir_merge_named themes

		# Caddy terminates TLS on this host and forwards to 127.0.0.1:8107.
		# Docker rewrites the source address of a published-port connection to
		# the gateway of the container's bridge network, and that gateway moves
		# when the network is recreated, so the range is what holds.
		http:
		  use_x_forwarded_for: true
		  trusted_proxies:
		    - 127.0.0.1/32
		    - 172.16.0.0/12
		  ip_ban_enabled: true
		  login_attempts_threshold: 5

		automation: !include automations.yaml
		script: !include scripts.yaml
		scene: !include scenes.yaml
	HACONF
fi
sudo test -f "$APP_DIR/config/automations.yaml" || printf '[]\n' | sudo tee "$APP_DIR/config/automations.yaml" >/dev/null
sudo touch "$APP_DIR/config/scripts.yaml" "$APP_DIR/config/scenes.yaml"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. No secrets to generate ----------------------------------------------
#
# There is deliberately nothing here. The owner account is created in a browser
# after this script finishes, and nothing else in this install has a password.

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-home-assistant"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8107 nor 8123 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8107 and 8123 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot installs the Python requirements for every integration
# default_config pulls in, so ten minutes of 502 is normal rather than broken.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/onboarding (this takes minutes on the first boot)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/onboarding" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
if [ "${code:-}" = "400" ]; then
	die "/api/onboarding answered 400: Home Assistant is rejecting a request from an untrusted proxy. Check $APP_DIR/config/configuration.yaml, then: docker compose restart"
fi
[ "${code:-}" = "200" ] || die "/api/onboarding answered ${code:-nothing}. Check: docker compose logs --tail 40 homeassistant"

curl -sS "https://${DOMAIN_HOST}/api/onboarding" | grep -q '"step":"user"' \
	|| die "/api/onboarding answered 200 without an onboarding step list. Check: docker compose logs --tail 40 homeassistant"

# The API must refuse an unauthenticated call.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------
#
# The recorder database is SQLite and is written constantly, so the container
# stops for the length of the tar. That is about ten seconds.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/home-assistant-${STAMP}.tar.gz" -C "$APP_DIR" config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/home-assistant-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Home Assistant is answering at https://${DOMAIN_HOST}/api/onboarding

	  1. Go to https://${DOMAIN_HOST} now and create the owner account. The
	     first screen says "Welcome!" with a "Create my smart home" button, and
	     until somebody submits that form anyone who loads the page can. Put the
	     password in your password manager.
	  2. Confirm it closed:
	       curl -sS https://${DOMAIN_HOST}/api/onboarding
	     It should now read "done":true for the user step.
	  3. The reverse proxy is configured in $APP_DIR/config/configuration.yaml,
	     under http:. Home Assistant answers 400 to every proxied request
	     without it, so if the site ever starts returning 400, read that file
	     first. Releases from the 2026.8 series move these settings into the
	     interface under Settings > System > Network.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as the
	     data, which is not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/home-assistant/
	     run from your own machine, not this one.

DONE
