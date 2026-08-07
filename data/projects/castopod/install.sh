#!/usr/bin/env bash
# Castopod · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=podcast.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.castopod.org/getting-started/docker.html
#   https://docs.castopod.org/getting-started/install.html
#   https://github.com/ad-aures/castopod/blob/v1.15.5/docker/production/s6-rc.d/bootstrap/prepare-environment.sh
#   https://mariadb.org/about/maintenance-policy/
#
# Four secrets are generated here, on this machine: the database password, the
# MariaDB root password, the Redis password and the analytics salt. All four go
# into /srv/castopod/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST becomes CP_BASEURL, the address inside your RSS feed and inside
# every audio file URL that feed hands a podcast app. Choose it once. Changing
# it later means keeping the old hostname alive as a redirect for years.
#
# This script stops one step short of finished, on purpose: only a human with a
# browser can fill in the Create your Super Admin account form, and until that
# account exists the installer is open to anyone who finds the URL. The closing
# summary says what to do and how to check it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/castopod}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. podcast.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP plus MariaDB plus Redis wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; audio makes this install want 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# Federation rejects signed requests from a server whose clock has drifted.
if command -v timedatectl >/dev/null 2>&1; then
	[ "$(timedatectl show -p NTPSynchronized --value)" = "yes" ] \
		|| die "the clock is not NTP-synced. Run: sudo timedatectl set-ntp true"
fi

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex for all four: they travel through a compose file, a connection string and
# a redis-server argument, and none of those wants escaping. The salt is 64
# characters, the length upstream's own generator produces. Read them later with
#   sudo grep -E 'PASSWORD|SALT' /srv/castopod/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		CP_BASEURL=https://${DOMAIN_HOST}/
		DB_PASSWORD=$(openssl rand -hex 32)
		DB_ROOT_PASSWORD=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
		CP_ANALYTICS_SALT=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-castopod"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8135, 3306 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8135, 3306 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The container writes its config, runs every migration, then starts the web
# server and a cron that fires every minute. Its log contains all four secrets,
# so never quote it back unfiltered:
#   docker compose logs --tail 40 castopod | grep -viE 'password|salt'

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 castopod | grep -viE 'password|salt'"

# Upstream returns 200 from /health only when the database, the cache handler
# and the media directory all answered.
curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"code":200' \
	|| die "/health answered 200 without code 200. Check: docker compose logs --tail 20 db"

# The installer must be up and on its final step, waiting for a human.
install_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/cp-install" || true)"
[ "$install_code" = "200" ] || die "/cp-install returned ${install_code}, not 200. Stop and investigate."
curl -sS "https://${DOMAIN_HOST}/cp-install" | grep -q 'Create your Super Admin account' \
	|| die "/cp-install did not render the Create your Super Admin account form"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/castopod-db-${STAMP}.sql.gz"
docker compose exec -T castopod tar -C /app/public/media -czf - . > "$APP_DIR/backups/castopod-media-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/castopod-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/castopod-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/castopod-media-${STAMP}.tar.gz" ] || die "the media archive is empty"

cat <<-DONE

	Castopod is answering at https://${DOMAIN_HOST}/health

	  1. FINISH THE INSTALL NOW, in a browser:
	       https://${DOMAIN_HOST}/cp-install
	     The form says Create your Super Admin account. Until you fill it in,
	     that page is open to anyone who finds it. Use a password of at least 8
	     characters that is not a dictionary word, and put it in your password
	     manager: self-registration is off, so it is the only way in, and there
	     is no reset path until you configure mail.
	  2. Then check the installer closed behind you:
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/cp-install
	     It must print 404. Anything else means no owner account exists yet.
	  3. Your four secrets are in $APP_DIR/.env, mode 600. None was printed
	     here, and none is printed by any command in this script. The container
	     log is the exception: it prints all four on every start, so read it as
	       docker compose logs --tail 40 castopod | grep -viE 'password|salt'
	  4. First backup written to $APP_DIR/backups: a database dump, the media
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight, and size that
	     somewhere for audio rather than for a database dump.

DONE
