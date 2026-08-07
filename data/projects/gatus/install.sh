#!/usr/bin/env bash
# Gatus · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=status.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/TwiN/gatus/blob/v5.36.0/README.md#configuration
#   https://github.com/TwiN/gatus/blob/v5.36.0/README.md#conditions
#   https://github.com/TwiN/gatus/blob/v5.36.0/README.md#storage
#   https://github.com/TwiN/gatus/blob/v5.36.0/README.md#docker
#   https://github.com/TwiN/gatus/blob/v5.36.0/Dockerfile
#
# No secret is generated here, because this install has none: Gatus ships no
# account, no registration form and no administration screen, and the one route
# that writes anything refuses every call without a bearer token that only the
# configuration file can declare. This one declares none.
#
# What it produces instead is a page anybody can read. Every endpoint name and
# every endpoint URL in config/config.yaml is published to whoever loads it.
# Read that file before you run this, and again every time you edit it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/gatus}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. status.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out, configuration first -------------------------------
#
# Gatus will not start without a configuration file, and the configuration is
# the product: monitors, conditions, alerting. It is written before the
# container has ever run.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/config"
sudo install -d -m 750 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

if [ ! -f "$APP_DIR/config/config.yaml" ]; then
	cat > "$APP_DIR/config/config.yaml" <<-'GATUSCONFIG'
		# Gatus · the configuration is the product. Authored by caniselfhostit from
		# https://github.com/TwiN/gatus/blob/v5.36.0/README.md#configuration
		#
		# Every name and every URL below is printed on a page anyone can open.

		storage:
		  type: sqlite
		  path: /data/data.db

		endpoints:
		  - name: gatus
		    group: internal
		    url: "http://127.0.0.1:8080/health"
		    interval: 60s
		    conditions:
		      - "[STATUS] == 200"
		      - "[BODY].status == UP"

		  - name: status-page
		    group: public
		    url: "https://<DOMAIN>/health"
		    interval: 60s
		    conditions:
		      - "[STATUS] == 200"
		      - "[RESPONSE_TIME] < 1000"
		      - "[CERTIFICATE_EXPIRATION] > 240h"

		  - name: dns
		    group: public
		    url: "1.1.1.1"
		    interval: 5m
		    dns:
		      query-name: "<DOMAIN>"
		      query-type: "A"
		    conditions:
		      - "[DNS_RCODE] == NOERROR"

		# Alerting is off. Every provider wants a webhook URL or a key from a service
		# you sign up for. To turn Slack on: uncomment, paste your own webhook URL, and
		# add an `alerts:` list with `- type: slack` under an endpoint.
		#alerting:
		#  slack:
		#    webhook-url: "PASTE_YOUR_OWN_SLACK_WEBHOOK_URL_HERE"
	GATUSCONFIG
	sed -i "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/config/config.yaml"
	chmod 600 "$APP_DIR/config/config.yaml"
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-gatus"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8132 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8132 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------
#
# Gatus runs every endpoint once at start-up rather than waiting out the first
# interval, so results exist seconds after the container comes up.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 gatus"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"status":"UP"' \
	|| die "/health answered 200 without status UP. Check: docker compose logs --tail 40 gatus"

# The dashboard renders this heading, so its absence means Caddy is reaching
# something other than Gatus.
curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Health Dashboard' \
	|| die "the page at https://${DOMAIN_HOST}/ does not carry the dashboard heading"

# The configuration loaded and the checks have already run once.
curl -sS "https://${DOMAIN_HOST}/api/v1/endpoints/statuses" | grep -q '"key":"public_status-page"' \
	|| die "the statuses API does not list the endpoints from config/config.yaml"

# The only route in this application that writes anything must refuse a call
# carrying no bearer token.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/v1/endpoints/public_status-page/external?success=true" || true)"
[ "$unauth" = "401" ] || die "the external push route returned ${unauth}, not 401. Stop and investigate."

# --- 6. The first backup, before day one ends --------------------------------
#
# Stopped on purpose: a SQLite file copied mid-write is not a backup. Downtime
# is about five seconds.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/gatus-${STAMP}.tar.gz" -C "$APP_DIR" config data compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/gatus-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Gatus is answering at https://${DOMAIN_HOST}

	  1. That page is public. It has no login, because it has no accounts, and
	     every endpoint name and URL in $APP_DIR/config/config.yaml is on it.
	     Open it in a private window and read it as a stranger would.
	  2. config/config.yaml is the product. Add monitors by editing it; Gatus
	     picks up the change within about thirty seconds. If the new file does
	     not parse, the container exits and keeps exiting, so check
	       cd $APP_DIR && docker compose logs --tail 20 gatus
	     before assuming anything else broke.
	  3. Alerting is off. The commented Slack block in that file is where your
	     own webhook URL goes, and nothing here signed you up for one.
	  4. Keep one free external check pointed at https://${DOMAIN_HOST} from a
	     service you do not run. This box cannot tell you that this box is down.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as the
	     data, which is not a backup. Copy it somewhere else tonight.

DONE
