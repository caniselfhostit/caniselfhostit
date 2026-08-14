#!/usr/bin/env bash
# VictoriaLogs · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=logs.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.victoriametrics.com/victorialogs/quickstart/
#   https://docs.victoriametrics.com/victorialogs/
#   https://docs.victoriametrics.com/victorialogs/security-and-lb/
#   https://docs.victoriametrics.com/victorialogs/data-ingestion/splunk/
#   https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# One secret is generated: the Caddy basic_auth password. VictoriaLogs itself
# has no accounts, no sign-in form and no first-run wizard, so Caddy is the only
# door on the public hostname. Apache-2.0; the plain image tag is the open
# source build, and the -enterprise tags in the same Docker Hub repository are a
# separate commercial product this script does not use.
#
# This script installs the log store. It does not make anything ship logs to it;
# the summary at the end says where that block goes.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/victorialogs}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# curl's own -w writes 000 on a failed connection; the || keeps set -e from
# ending the script before the assert below can name what it received.
http_code() {
	local out
	out="$(curl -sS -o /dev/null -w '%{http_code}' "$@")" || out="000"
	printf '%s' "$out"
}

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. logs.example.com"
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
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; a log store wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')" || resolved=""
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Layout ---------------------------------------------------------------
#
# data/ becomes /vlogs inside the container and is the only thing it writes.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" \
	"$APP_DIR" "$APP_DIR/backups" "$APP_DIR/data"
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
printf 'basic_auth {\n\tvlogs %s\n}\n' "$(cat "$APP_DIR/auth.hash")" > "$APP_DIR/auth.conf"
umask 022
sudo install -m 640 -o root -g caddy "$APP_DIR/auth.conf" /etc/caddy/victorialogs-auth.conf
rm -f "$APP_DIR/auth.hash" "$APP_DIR/auth.conf"
sudo grep -q basic_auth /etc/caddy/victorialogs-auth.conf \
	|| die "the auth conf has no basic_auth block; publishing the site block now would expose an open log store"

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-victorialogs"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Firewall -------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8190 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start and assert -----------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8190/health"
code=""
for _ in $(seq 1 30); do
	code="$(http_code "http://127.0.0.1:8190/health")"
	if [ "$code" = "200" ]; then break; fi
	sleep 5
done
[ "$code" = "200" ] || die "loopback /health answered ${code}. Check: docker compose logs --tail 40 victorialogs"

ingest="$(printf '{"_msg":"caniselfhostit install check","service":"install-check"}\n' \
	| curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/stream+json' \
	  --data-binary @- 'http://127.0.0.1:8190/insert/jsonline?_stream_fields=service')" || ingest="000"
echo "==> jsonline ingest -> ${ingest}"
[ "$ingest" = "200" ] || die "the jsonline ingest endpoint answered ${ingest}, not 200"

sleep 3
found="$(curl -sS "http://127.0.0.1:8190/select/logsql/query" -d 'query={service="install-check"}' \
	| grep -c 'caniselfhostit install check')" || found="0"
echo "==> query returned ${found} matching line(s)"
[ "$found" -ge 1 ] || die "the ingested line did not come back from /select/logsql/query; the insert was accepted but nothing is queryable"

unauth="$(http_code "https://${DOMAIN_HOST}/select/vmui/")"
echo "==> unauthenticated https://${DOMAIN_HOST}/select/vmui/ -> ${unauth}"
[ "$unauth" = "401" ] || die "unauthenticated public request returned ${unauth}, not 401. The log store is reachable without a password; fix Caddy before using this."

auth="$(http_code -u "vlogs:$(cat "$APP_DIR/dashboard-password")" "https://${DOMAIN_HOST}/select/vmui/")"
echo "==> authenticated https://${DOMAIN_HOST}/select/vmui/ -> ${auth}"
[ "$auth" = "200" ] || die "authenticated public request returned ${auth}, not 200"

# --- 7. First backup ---------------------------------------------------------
#
# Stopped on purpose: a storage directory copied while partitions are being
# merged is not a backup. Downtime is a few seconds.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/victorialogs-${STAMP}.tar.gz" \
	-C "$APP_DIR" data compose.yml dashboard-password \
	-C /etc/caddy Caddyfile victorialogs-auth.conf
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/victorialogs-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	VictoriaLogs is answering at https://${DOMAIN_HOST}/select/vmui/

	  1. Sign in as vlogs. Read the password with:
	       sudo cat ${APP_DIR}/dashboard-password
	     VictoriaLogs has no account of its own; Caddy is the door, and the
	     401 and 200 above are the proof it is shut and openable.
	  2. Nothing ships logs here yet. Add this to a service in its own compose
	     file, keep the keys already there, then recreate that one service with
	     docker compose up -d --force-recreate <service>:

	       logging:
	         driver: splunk
	         options:
	           splunk-url: "http://127.0.0.1:8190"
	           splunk-token: "PLACEHOLDER"
	           splunk-verify-connection: "false"
	           tag: "{{.Name}}"

	     The token is ignored by VictoriaLogs. The connection check is off
	     because the driver expects a 200 to an OPTIONS probe and VictoriaLogs
	     answers 204, which would stop the container from starting. Never put
	     this block on the victorialogs service itself.
	  3. Then confirm lines are landing:
	       curl -sS http://127.0.0.1:8190/select/logsql/query -d 'query=_time:5m'
	  4. Retention is 30 days with a 5 GiB ceiling on ${APP_DIR}/data, both set
	     in compose.yml. Watch: du -sh ${APP_DIR}/data
	  5. First backup at ${APP_DIR}/backups. It carries the password file, so
	     treat it as secret. Copy it off this disk tonight.
	  6. NOT YET VERIFIED on a clean harness machine.

DONE
