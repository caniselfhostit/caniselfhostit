#!/usr/bin/env bash
# Countly Lite · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=analytics.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream sources:
#   https://github.com/Countly/countly-server/blob/25.03.51/Dockerfile-core
#   https://github.com/Countly/countly-server/blob/25.03.51/api/config.sample.js
#   https://github.com/Countly/countly-server/blob/25.03.51/frontend/express/config.sample.js
#   https://github.com/Countly/countly-server/blob/25.03.51/bin/commands/scripts/healthcheck/accessibility.sh
#
# Two secrets are generated here, on this machine: the dashboard session secret
# and the password secret Countly mixes into every stored password. Both go into
# /srv/countly/.env with mode 600 and neither is ever printed.
#
# DOMAIN_HOST is the address every SDK you install afterwards posts events to, so
# it ends up in the source of every app and page you measure. Choose it once.
#
# This script cannot create the first administrator account or the first
# application: both happen in a browser. It stops with instructions for that.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/countly}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. analytics.example.com"
case "$DOMAIN_HOST" in
	*/*|http*) die "DOMAIN_HOST is a bare hostname, with no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

# Upstream publishes countly-core for amd64 only. There is no arm tag.
arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this box is ${arch}; upstream publishes the Countly image for amd64 only"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; two Node processes plus MongoDB want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No directory for Countly itself: upstream defaults file storage to GridFS, so
# uploads and app icons are documents in MongoDB. The database directory is left
# owned by root because the MongoDB image chowns it on first start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mongo"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# WEB_SESSION_SECRET replaces the value upstream publishes in its sample config.
# PASSWORDSECRET is mixed into every password before hashing, so it has to exist
# before the first account does; changing it later invalidates every password
# already stored. Read them yourself with
#   sudo cat /srv/countly/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		COUNTLY_CONFIG_FRONTEND_WEB_SESSION_SECRET=$(openssl rand -hex 32)
		COUNTLY_CONFIG_FRONTEND_PASSWORDSECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-countly"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8174 nor 27017 is one of them -----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8174 and 27017 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The image writes its plugin list and loads a city database into MongoDB on
# first boot, before nginx answers anything, so the wait below is generous.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ping"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/ping" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/ping answered ${code:-nothing}. Check: docker compose logs --tail 40 countly"

# The dashboard's own health endpoint answers only after it has reached MongoDB.
curl -sS "https://${DOMAIN_HOST}/ping" | grep -q 'Success' \
	|| die "/ping returned 200 without the word Success. Check: docker compose logs --tail 40 countly"

# The collection API's, which is a different process inside the same container.
curl -sS "https://${DOMAIN_HOST}/o/ping" | grep -q '"result":"Success"' \
	|| die "/o/ping did not answer {\"result\":\"Success\"}. The API process is not up."

# The registration screen is served only while the members collection is empty.
curl -sS "https://${DOMAIN_HOST}/setup" | grep -q 'data-localize="setup.ready"' \
	|| die "the setup screen is not being served. Either the dashboard is still starting, or this install already has an account."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mongodb mongodump --quiet --archive --gzip > "$APP_DIR/backups/countly-db-${STAMP}.archive.gz"
sudo tar -czf "$APP_DIR/backups/countly-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/countly-db-${STAMP}.archive.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/countly-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Countly Lite is answering at https://${DOMAIN_HOST}/ping

	  1. Claim it NOW, at https://${DOMAIN_HOST}/setup
	     Until you do, the first person who finds that hostname becomes the
	     administrator. The screen reads "Your Countly server is ready!".
	     There is no mail server here, so that password has no reset link:
	     put it in your password manager as you type it. The wizard after it
	     asks whether to enable Countly's own analytics on this server; the
	     compose file already answers no.
	  2. Add your first application in the same wizard, then confirm the
	     install is claimed and that it accepts events:
	       cd $APP_DIR
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/setup
	       key=\$(docker compose exec -T mongodb mongosh --quiet countly --eval 'const a=db.apps.findOne({}); print(a ? (a.key || (a.keys && a.keys[0] && a.keys[0].key) || "") : "")' | tr -d '\r\n')
	       curl -sS "https://${DOMAIN_HOST}/i?app_key=\${key}&device_id=selfhost-check&begin_session=1"; echo
	     The first prints 302 and the second {"result":"Success"}.
	  3. Point something at it. The web SDK loads from
	       https://${DOMAIN_HOST}/sdk/web/countly.min.js
	     and takes the app key printed above plus that URL. Nothing appears on
	     the dashboard until an SDK is sending, and that is not a fault.
	  4. Your two secrets are in $APP_DIR/.env, mode 600, and were not printed
	     here. The password secret is mixed into every stored password, so a
	     database restored beside the wrong .env gives you back every account
	     and no way into any of them.
	  5. First backup written to $APP_DIR/backups: a MongoDB archive and a
	     config archive. They are on the same disk as the data, which is not a
	     backup. Copy them off tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/countly/

DONE
