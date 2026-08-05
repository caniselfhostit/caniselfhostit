#!/usr/bin/env bash
# FreshRSS · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=rss.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/FreshRSS/FreshRSS/blob/edge/Docker/README.md
#   https://freshrss.github.io/FreshRSS/en/admins/08_FeedUpdates.html
#   https://freshrss.github.io/FreshRSS/en/admins/05_Backup.html
#   https://freshrss.github.io/FreshRSS/en/admins/Caddy.html
#
# One secret is generated here, on this machine: the password for your own
# FreshRSS account. It is written to /srv/freshrss/.env with mode 600 and it is
# never printed to the terminal.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/freshrss}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_USER="${ADMIN_USER:-admin}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. rss.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data/ is owned by uid 33 because that is www-data inside the image, and Apache
# in the container is the process that writes the SQLite database.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 33 -g 33 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# This password has never existed anywhere else: not in the prompt, not in a chat
# window, not in this repository. Read it later with
#   sudo grep ADMIN_PASSWORD /srv/freshrss/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		TZ=UTC
		CRON_MIN=13,43
		TRUSTED_PROXY=172.16.0.0/12
		ADMIN_USER=${ADMIN_USER}
		ADMIN_PASSWORD=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-freshrss"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8084 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8084 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it, then install it non-interactively --------------------------
#
# The web installer is skipped on purpose. It is open to whoever reaches the
# hostname first until somebody completes it, and cli/do-install.php closes that
# window without a browser being involved. The password is read from the
# container's own environment, so it never appears on a command line.

docker compose pull
docker compose up -d
sleep 15

docker compose exec -T --user www-data freshrss cli/do-install.php --default-user "$ADMIN_USER" \
	|| echo "==> do-install reported nothing to do; data/config.php already exists"
docker compose exec -T --user www-data freshrss \
	sh -c 'cli/create-user.php --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"' \
	|| echo "==> create-user reported nothing to do; the account already exists"

sudo test -f "$APP_DIR/data/config.php" || die "data/config.php was not written, so the web installer is still open"

# --- 7. Prove it works before claiming it does -------------------------------

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs freshrss"

curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'FreshRSS' \
	|| die "the page answered 200 but does not mention FreshRSS. Check: docker compose logs freshrss"

# --- 8. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/freshrss-$(date +%Y%m%d-%H%M%S).tar.gz" data .env
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	FreshRSS is running at https://${DOMAIN_HOST}/

	  1. Your username is ${ADMIN_USER}. Read the password once with
	     sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     put it in your password manager, and do not paste it anywhere else.
	  2. Add a feed, then wait. Feeds refresh at 13 and 43 minutes past the
	     hour, and FreshRSS will not refresh any feed more often than every
	     twenty minutes. An empty reader for half an hour is normal.
	  3. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
