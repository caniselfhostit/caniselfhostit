#!/usr/bin/env bash
# draw.io · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=draw.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/jgraph/docker-drawio/blob/v31.1.8/README.md
#   https://github.com/jgraph/docker-drawio/blob/v31.1.8/main/docker-entrypoint.sh
#   https://github.com/jgraph/docker-drawio/blob/v31.1.8/main/Dockerfile
#   https://caddyserver.com/docs/automatic-https
#
# Before you run this, know what it is for. draw.io's own hosted editor at
# https://app.diagrams.net is free and asks for no account, and it is the same
# editor. This install changes where the page comes from, not what it does: your
# hostname, your machine, no third-party origin serving the code. If that is not
# the thing you needed, you have not lost anything by closing the file here.
#
# One secret is generated on this machine: KEYSTORE_PASS, which replaces the
# value the image would otherwise take from its own public documentation for the
# self-signed certificate it builds at every start. It goes into /srv/drawio/.env
# with mode 600 and is never printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/drawio}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. draw.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; a Tomcat on a JVM wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# There is no data directory here and none is missing. The container writes no
# diagram to this server, so the only files under $APP_DIR are the two below.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Read it later, if you ever need to, with
#   sudo grep KEYSTORE_PASS /srv/drawio/.env
# Nothing in this install will ask you to type it.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DRAWIO_SERVER_URL=https://${DOMAIN_HOST}/
		KEYSTORE_PASS=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-drawio"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8158 nor 8443 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8158 and 8443 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Tomcat rewrites the editor's configuration files from the environment at every
# start, so the first boot is slower than the ones after it.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 20); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the site answered ${code:-nothing}. Check: docker compose logs --tail 40 drawio"

curl -sS "https://${DOMAIN_HOST}/" | grep -q 'Flowchart Maker' \
	|| die "the page did not carry the editor's title. Check: docker compose logs --tail 40 drawio"

# The security assert: the container's generated configuration must have every
# cloud storage backend switched off, so nobody loading this editor is offered
# somewhere else to put their diagram.
preconfig="$(curl -sS "https://${DOMAIN_HOST}/js/PreConfig.js" || true)"
printf '%s' "$preconfig" | grep -qF "urlParams['gapi'] = '0'" \
	|| die "PreConfig.js does not switch the Google Drive backend off. Stop and investigate."
printf '%s' "$preconfig" | grep -qF "window.DRAWIO_SERVER_URL = 'https://${DOMAIN_HOST}/'" \
	|| die "PreConfig.js does not carry this hostname, so /srv/drawio/.env did not reach the container."

# --- 7. The first backup, before day one ends --------------------------------
#
# There is no database to dump and no data directory to archive. This archives
# the configuration that rebuilds the service, including the live Caddy file
# with the real hostname substituted into it.

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/drawio-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/drawio-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	draw.io is answering at https://${DOMAIN_HOST}/

	  1. Open https://${DOMAIN_HOST}/?offline=1 and you get a dialog headed
	     "Save diagrams to:" with two buttons, Device and Browser, and a
	     "Decide Later" link. No Google Drive, no OneDrive, no GitHub: this
	     script asserted those are off before it printed this.
	  2. There is no account and no password, because draw.io has neither.
	     Anyone who reaches this hostname gets their own blank canvas. They
	     cannot see your diagrams, because your diagrams are not here.
	  3. Nothing is stored on this server. Device saves a file on the computer
	     you are sitting at; Browser saves into that one browser's storage.
	     Draw something now and use File then Save As, because that file is the
	     only copy of your work that a backup can ever reach.
	  4. First backup written to $APP_DIR/backups: compose.yml, .env and the
	     live Caddy site block. It is on the same disk as the install, which is
	     not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/drawio/

DONE
