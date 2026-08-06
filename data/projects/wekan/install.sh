#!/usr/bin/env bash
# WeKan · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=boards.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/wekan/wekan/blob/v10.71/docker-compose-mongodb-v7.yml
#   https://github.com/wekan/wekan/blob/v10.71/docs/Webserver/Settings.md
#   https://github.com/wekan/wekan/blob/v10.71/docs/Login/Adding-users.md
#   https://github.com/wekan/wekan/blob/v10.71/docs/Backup/Backup.md
#
# No secrets are generated here. WeKan has no admin token, and its only
# credential is the first account, which you create in a browser at the end.
# MongoDB runs without one, publishes no host port, and is reachable only from
# the WeKan container.
#
# DOMAIN_HOST becomes ROOT_URL. A Meteor application opens its live data socket
# at whatever ROOT_URL says, so this value has to be the hostname you browse to,
# with no trailing slash.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/wekan}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. boards.example.com"
case "$DOMAIN_HOST" in
	*/*|http*) die "DOMAIN_HOST is a bare hostname, with no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; WeKan plus MongoDB wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

# MongoDB 7 needs AVX on x86. Without it mongod exits during start-up, and no
# environment variable changes that.
if [ "$(dpkg --print-architecture)" = "amd64" ]; then
	grep -q -w avx /proc/cpuinfo || die "this amd64 CPU has no AVX flag, so MongoDB 7 will not start on it"
fi

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No data directories here: MongoDB chowns /data/db to its own uid and the WeKan
# image chowns /data to a system user made at image build time, so both live in
# named volumes and section 7 backs them up through the containers.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. The one configured value, on the server ------------------------------

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	printf 'ROOT_URL=https://%s\n' "$DOMAIN_HOST" > "$APP_DIR/.env"
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-wekan"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8104 nor 27017 is one of them -----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8104 and 27017 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MongoDB reports unhealthy until its one-member replica set is initiated, which
# is what creates the oplog Meteor tails, so the database starts alone first.

docker compose pull
docker compose up -d wekandb

echo "==> waiting for mongod to answer"
for _ in $(seq 1 20); do
	docker compose exec -T wekandb mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1 && break
	sleep 5
done
docker compose exec -T wekandb mongosh --quiet --eval \
	'try { rs.status().ok } catch (e) { rs.initiate({_id: "rs0", members: [{_id: 0, host: "wekandb:27017"}]}).ok }' \
	|| die "the replica set would not initiate. Check: docker compose logs --tail 20 wekandb"

docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/sign-in"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/sign-in" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/sign-in answered ${code:-nothing}. Check: docker compose logs --tail 40 wekan"

# WeKan writes this title into every page it serves, so it is the proof that the
# application answered rather than Caddy alone.
curl -sS "https://${DOMAIN_HOST}/sign-in" | grep -q '<title>Wekan</title>' \
	|| die "/sign-in returned 200 without <title>Wekan</title>. Something else is answering."

# The live data socket's own endpoint, reached through Caddy.
sockjs="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/sockjs/info" || true)"
[ "$sockjs" = "200" ] || die "/sockjs/info returned ${sockjs}, not 200. Boards will never finish loading."

# ROOT_URL is the value this install is most likely to get wrong.
root_url="$(docker compose exec -T wekan printenv ROOT_URL | tr -d '\r\n')"
[ "$root_url" = "https://${DOMAIN_HOST}" ] || die "ROOT_URL in the container is '${root_url}', not https://${DOMAIN_HOST}"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T wekandb mongodump --quiet --archive --gzip --db=wekan > "$APP_DIR/backups/wekan-db-${STAMP}.archive.gz"
docker compose exec -T wekan tar -C /data -czf - . > "$APP_DIR/backups/wekan-files-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/wekan-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/wekan-db-${STAMP}.archive.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/wekan-files-${STAMP}.tar.gz" ] || die "the attachments archive is empty"

cat <<-DONE

	WeKan is answering at https://${DOMAIN_HOST}/sign-in

	  1. Register the first account NOW, at https://${DOMAIN_HOST}/sign-up
	     Upstream: the first registered user becomes the administrator and
	     later ones are ordinary users, so until you do this the hostname is
	     open to whoever finds it. An "Internal Server Error" on that screen
	     is upstream's documented answer when no mail server is configured;
	     the account is created anyway, so sign in and check.
	  2. Then close registration, and confirm it took:
	       cd $APP_DIR
	       printf 'db.settings.updateOne({}, {\$set: {disableRegistration: true, modifiedAt: new Date()}});\n' | docker compose exec -T wekandb mongosh --quiet wekan
	       docker compose restart wekan
	       printf 'print(db.settings.findOne({}).disableRegistration);\n' | docker compose exec -T wekandb mongosh --quiet wekan
	     The second command prints true, and the register link disappears
	     from the sign-in page.
	  3. First backup written to $APP_DIR/backups: a database dump, an
	     attachments archive and a config archive. They are on the same disk
	     as the data, which is not a backup. Copy them off tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/wekan/
	  4. If a board ever hangs on a loading spinner, check ROOT_URL first:
	       docker compose exec -T wekan printenv ROOT_URL

DONE
