#!/usr/bin/env bash
# Backrest · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=backup.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/garethgeorge/backrest/blob/v1.14.1/README.md
#   https://garethgeorge.github.io/backrest/introduction/getting-started
#   https://garethgeorge.github.io/backrest/docs/operations
#   https://github.com/garethgeorge/backrest/blob/v1.14.1/cmd/docker-entrypoint/main.go
#
# One secret is generated here, on this machine: the password for the web login.
# It goes into /srv/backrest/.env with mode 600 and is never printed. Its bcrypt
# hash goes into /srv/backrest/config/config.json before the container has ever
# run, because a Backrest that starts with no configuration file writes itself a
# default one with authentication disabled and then serves every API route to
# whoever asks.
#
# The repository passwords you type into the UI later are restic encryption
# passwords. Nothing here can recover one. Keep them where you keep this login.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/backrest}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
PORT="8136"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. backup.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Backrest and restic want 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB for the image and restic's cache"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# config and backups belong to the login user; data, cache and restore are
# written by the container, which runs as root because the files it reads under
# /srv were written by other services as other users.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/config"
sudo install -d -m 700 "$APP_DIR/data" "$APP_DIR/cache" "$APP_DIR/restore"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64, because a human types this one into a login form.
# Read it later with
#   sudo grep BACKREST_PASSWORD /srv/backrest/.env
# Backrest stores a password as a bcrypt hash that is then base64 encoded, and
# `caddy hash-password` piped into `base64` is exactly that. `version` is
# required: a configuration file with content and no version number is rejected
# at start-up, and 6 is the migration count this release ships.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BACKREST_USERNAME=admin
		BACKREST_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

if [ ! -f "$APP_DIR/config/config.json" ]; then
	umask 077
	cat > "$APP_DIR/config/config.json" <<-'CONFIGJSON'
		{
		  "version": 6,
		  "instance": "INSTANCE_NAME",
		  "auth": {"disabled": false, "users": [{"name": "admin", "passwordBcrypt": "PLACEHOLDER"}]}
		}
	CONFIGJSON
	grep BACKREST_PASSWORD "$APP_DIR/.env" | cut -d= -f2- | caddy hash-password | base64 | tr -d '\n' > "$APP_DIR/config/hash.tmp"
	awk -v host="$DOMAIN_HOST" 'NR==FNR{h=$0;next} {sub(/PLACEHOLDER/,h);sub(/INSTANCE_NAME/,host);print}' \
		"$APP_DIR/config/hash.tmp" "$APP_DIR/config/config.json" > "$APP_DIR/config/config.tmp"
	mv "$APP_DIR/config/config.tmp" "$APP_DIR/config/config.json"
	rm "$APP_DIR/config/hash.tmp"
	chmod 600 "$APP_DIR/config/config.json"
	umask 022
fi
if grep -q PLACEHOLDER "$APP_DIR/config/config.json"; then
	die "the bcrypt hash was not substituted into config.json"
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-backrest"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8136 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; ${PORT} stays closed on loopback"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs --tail 40 backrest"

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>Backrest</title>' \
	|| die "the page at https://${DOMAIN_HOST}/ is not Backrest's. Check the Caddy site block from step 4."

# The API must refuse a call with no credentials. If this returns 200 the
# configuration file was not read and the instance is open to the internet.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/v1.Backrest/GetOperations" \
	-H 'Content-Type: application/json' -d '{}' || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop: authentication is off."

# And it must accept the generated one. The password goes to curl through a
# config on standard input, so it never appears in a command line or a log.
authed="$(printf 'user = "admin:%s"\n' "$(sudo grep BACKREST_PASSWORD "$APP_DIR/.env" | cut -d= -f2-)" \
	| curl -sS -o /dev/null -w '%{http_code}' -K - -X POST "https://${DOMAIN_HOST}/v1.Backrest/GetOperations" \
	-H 'Content-Type: application/json' -d '{}' || true)"
[ "$authed" = "200" ] || die "the generated login returned ${authed}, not 200. The hash and the password disagree."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/backrest-config-${STAMP}.tar.gz" -C "$APP_DIR" config data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/backrest-config-${STAMP}.tar.gz" ] || die "the configuration archive is empty"

cat <<-DONE

	Backrest is answering at https://${DOMAIN_HOST}/ and refusing unauthenticated API calls.

	  1. Your login is admin. The password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep BACKREST_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Nothing is backed up yet. Open https://${DOMAIN_HOST}/, log in, then Add Repo
	     for the storage your snapshots go to, then Add Plan for the paths. This
	     server's /srv is /userdata inside the container, and /userdata/backrest
	     belongs in the excludes: it is this app's own cache and history.
	  3. The repository password you type there is a restic encryption password.
	     Lose it and every snapshot is unreadable, including by you.
	  4. Restore one file from your first snapshot into /restore and look at it with
	       sudo ls -lR $APP_DIR/restore
	     A backup nobody has restored is a hope.
	  5. First backup of this install written to $APP_DIR/backups. It holds .env and
	     config.json, so it holds every repository password. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
