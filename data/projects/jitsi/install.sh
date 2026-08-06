#!/usr/bin/env bash
# Jitsi Meet · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=meet.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker/
#   https://github.com/jitsi/docker-jitsi-meet/blob/stable-11146-1/env.example
#   https://github.com/jitsi/docker-jitsi-meet/blob/stable-11146-1/docker-compose.yml
#
# Three secrets are generated here, on this machine: the two XMPP service
# passwords and the password for the moderator account. All three go into
# /srv/jitsi/.env with mode 600 and none is ever printed.
#
# Two things about this install that are unlike the rest of the catalogue.
# Media does not pass through Caddy: it goes to 10000/udp, at the videobridge,
# so that port is opened and the address in the A record is written into
# JVB_ADVERTISE_IPS. And a fresh Jitsi with no authentication is an open
# conference server, so ENABLE_AUTH is on and only the account registered
# below can open a room.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/jitsi}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. meet.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; two JVMs plus Prosody and nginx want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Upstream states the containers run as uid 1000 and check on startup that the
# directories they write to are writable by it, so those are owned by 1000
# rather than by the login user.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/prosody"
sudo install -d -m 755 -o 1000 -g 1000 "$APP_DIR/config" "$APP_DIR/config/web" \
	"$APP_DIR/config/prosody" "$APP_DIR/config/jicofo" "$APP_DIR/config/jvb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Read the moderator password later with
#   grep MEET_HOST_PASSWORD /srv/jitsi/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PUBLIC_URL=https://${DOMAIN_HOST}
		JICOFO_AUTH_PASSWORD=$(openssl rand -hex 32)
		JVB_AUTH_PASSWORD=$(openssl rand -hex 32)
		MEET_HOST_PASSWORD=$(openssl rand -base64 24)
		JVB_ADVERTISE_IPS=${resolved}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-jitsi"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: four open, and 8114 is not one of them ------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3, 10000/udp for media; 8114 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw allow 10000/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the site answered ${code:-nothing}. Check: docker compose logs --tail 40 web"

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>Jitsi Meet</title>' \
	|| die "the page came back without the Jitsi Meet title. Check: docker compose logs --tail 40 web"

# Authenticated room creation must have reached the browser config. These two
# lines are generated only when ENABLE_AUTH and ENABLE_GUESTS are both on.
curl -sS "https://${DOMAIN_HOST}/config.js" | grep -q 'config.hosts.authdomain' \
	|| die "config.js has no authdomain, so room creation is open. Stop and fix step 4."

ss -lun | grep -q ':10000' || die "nothing is listening on 10000/udp, so no call will carry media"

# --- 7. The moderator account, and the assert that nobody else can open a room

docker compose exec -T prosody sh -c \
	'prosodyctl --config /run/prosody/config/prosody.cfg.lua register moderator meet.jitsi "$MEET_HOST_PASSWORD"' >/dev/null
docker compose exec -T prosody find /var/lib/prosody -name 'moderator.dat' | grep -q 'moderator.dat' \
	|| die "the moderator account was not created. Check: docker compose logs --tail 40 prosody"
docker compose exec -T prosody awk '/^VirtualHost "meet.jitsi"$/,/^VirtualHost /' \
	/run/prosody/config/conf.d/jitsi-meet.cfg.lua | grep -q 'authentication = "internal_hashed"' \
	|| die "the meeting domain is not on internal authentication. Anyone could open a room. Stop."

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/jitsi-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env prosody -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/jitsi-config-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Jitsi Meet is answering at https://${DOMAIN_HOST}/

	  1. Only the account "moderator" can open a meeting. Its password is in
	     $APP_DIR/.env, mode 600. Read it with
	       grep MEET_HOST_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Open https://${DOMAIN_HOST}/, type a room name, and sign in as
	     moderator when asked. Guests can join a room you have opened; they
	     cannot open one. Add more hosts with
	       docker compose exec -T prosody prosodyctl --config /run/prosody/config/prosody.cfg.lua register NAME meet.jitsi
	  3. Media does not travel through Caddy. It goes to 10000/udp, at the
	     videobridge, advertised on the address in JVB_ADVERTISE_IPS. If a call
	     connects with no sound, that line and that port are where to look, in
	     that order, before anything else.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
