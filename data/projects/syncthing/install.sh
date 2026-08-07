#!/usr/bin/env bash
# Syncthing · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=sync.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/syncthing/syncthing/blob/v2.1.3/README-Docker.md
#   https://docs.syncthing.net/users/config.html
#   https://docs.syncthing.net/users/firewall.html
#   https://docs.syncthing.net/users/untrusted.html
#
# One secret is generated here, on this machine: the web GUI password. It goes
# into /srv/syncthing/.env with mode 600, is never printed, and becomes a bcrypt
# hash inside config.xml before the server ever listens.
#
# The second password this install needs is deliberately not generated here. The
# folder encryption password is typed on your own computer when you share the
# folder, and it must never be stored on this server. That is what makes this
# box an untrusted peer rather than merely a remote one.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/syncthing}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. sync.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB before any synced files"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image runs Syncthing as uid 1000 and hands the mount root to that uid on
# every start, so these three directories are created owned by it.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/data" "$APP_DIR/data/config" "$APP_DIR/data/sync"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: the value travels through a pipe into a container in
# section 6 and hex holds nothing a shell treats as special. Read it later with
#   grep -F GUI_PASSWORD /srv/syncthing/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		GUI_USER=admin
		GUI_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------
#
# This hostname carries the web GUI only. The sync protocol on 22000 is a
# device-to-device TLS session that no reverse proxy can terminate.

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-syncthing"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: five open, and 8139 and 21027 are not among them --------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3, 22000/tcp and 22000/udp for the"
	echo "==> sync protocol, which peers reach directly. 8139 and 21027 stay closed."
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw allow 22000/tcp
	sudo ufw allow 22000/udp
	sudo ufw status verbose
fi

# --- 6. Write the config, then start -----------------------------------------
#
# The GUI password becomes a bcrypt hash in config.xml before the server ever
# listens, so there is no window in which the interface answers without one. The
# six sed edits turn off every outbound connection this box would otherwise make
# to infrastructure you do not run: global discovery, LAN announcements, the
# community relay pool, STUN and UPnP, crash reporting and usage reporting. A
# server with a fixed public address and an open 22000 needs none of them.

docker compose pull

if [ ! -f "$APP_DIR/data/config/config.xml" ]; then
	grep -F GUI_PASSWORD "$APP_DIR/.env" | cut -d= -f2- \
		| docker compose run --rm -T syncthing generate --gui-user admin --gui-password - --no-port-probing
	sudo sed -i -E 's#<(globalAnnounceEnabled|localAnnounceEnabled|relaysEnabled|natEnabled|crashReportingEnabled)>true<#<\1>false<#; s#<urAccepted>0<#<urAccepted>-1<#' "$APP_DIR/data/config/config.xml"
	sudo chown 1000:1000 "$APP_DIR/data/config/config.xml"
fi

knobs="$(sudo grep -cE '>false</(globalAnnounce|localAnnounce|relays|nat|crashReporting)Enabled>|<urAccepted>-1<' "$APP_DIR/data/config/config.xml" || true)"
[ "$knobs" = "6" ] || die "config.xml has ${knobs} of the 6 expected settings. Stop: it is not the shape this script wrote."

docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/rest/noauth/health"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/rest/noauth/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/rest/noauth/health answered ${code:-nothing}. Check: docker compose logs --tail 40 syncthing"

curl -sS "https://${DOMAIN_HOST}/rest/noauth/health" | grep -q '"status": "OK"' \
	|| die "the health endpoint answered 200 without status OK. Check: docker compose logs --tail 40 syncthing"

# The API must refuse an unauthenticated call. Upstream answers 403 when no
# session cookie, API key or basic auth is present.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/rest/system/status" || true)"
[ "$unauth" = "403" ] || die "an unauthenticated API call returned ${unauth}, not 403. Stop and investigate."

curl -sS "https://${DOMAIN_HOST}/" | grep -q 'Authentication Required' \
	|| die "the first screen does not carry 'Authentication Required'. Stop and investigate."

running="$(curl -sSI "https://${DOMAIN_HOST}/" | awk 'tolower($1)=="x-syncthing-version:"{print $2}' | tr -d '\r')"
[ "$running" = "v2.1.3" ] || die "the running version is ${running:-unknown}, not v2.1.3"

DEVICE_ID="$(curl -sSI "https://${DOMAIN_HOST}/" | awk 'tolower($1)=="x-syncthing-id:"{print $2}' | tr -d '\r')"
[ -n "$DEVICE_ID" ] || die "the server did not report a Device ID"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/syncthing-${STAMP}.tar.gz" -C "$APP_DIR" data/config compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/syncthing-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Syncthing is answering at https://${DOMAIN_HOST}

	  Device ID: ${DEVICE_ID}

	  1. Your login is admin. The password is in $APP_DIR/.env, mode 600. Read
	     it with
	       grep -F GUI_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Nothing syncs yet. On the computer that holds your files, install
	     Syncthing from https://syncthing.net/downloads/, add the Device ID
	     above as a remote device, set its address to tcp://${DOMAIN_HOST}:22000,
	     and tick Untrusted on the Advanced tab. Approve it here as well.
	  3. Then share one folder from that computer and set an encryption password
	     for this device. Create that password on your own computer. Never type
	     it into the interface on this server and never write it into a file
	     here: that is the whole point, and losing it makes the copy on this box
	     unreadable forever.
	  4. When this server offers to add the folder, set Folder Path to
	     /var/syncthing/sync and Folder Type to Receive Encrypted before saving.
	     That choice cannot be changed afterwards. Check it landed with
	       sudo grep -c 'type="receiveencrypted"' $APP_DIR/data/config/config.xml
	  5. First backup written to $APP_DIR/backups: config.xml, the device key,
	     the database and the live Caddy block. It is on the same disk as the
	     data, which is not a backup. Copy it somewhere else tonight. The file
	     that matters most in it is data/config/key.pem, this server's identity.

DONE
