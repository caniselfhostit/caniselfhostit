#!/usr/bin/env bash
# wallabag · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=read.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/wallabag/docker/blob/master/README.md
#   https://github.com/wallabag/docker/blob/master/root/entrypoint.sh
#   https://github.com/wallabag/docker/blob/master/root/etc/wallabag/parameters.template.yml
#   https://doc.wallabag.org/admin/parameters/
#
# Two secrets are generated here, on this machine: the Symfony application
# secret and the password that replaces the one the image ships with. Both go
# into /srv/wallabag/.env with mode 600 and neither is ever printed.
#
# DOMAIN_HOST is also SYMFONY__ENV__DOMAIN_NAME, the hostname wallabag puts in
# every feed URL and share link it generates.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/wallabag}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. read.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; nginx plus php-fpm wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data and images belong to uid 65534. The image chowns /var/www/wallabag to
# nobody when it is built and runs php-fpm as that user, so a directory owned by
# anyone else is one wallabag cannot write to.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 65534 -g 65534 "$APP_DIR/data" "$APP_DIR/images"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# The application secret is hex because it lands in a YAML file that the image
# generates with envsubst, and hex needs no quoting there. Read either value
# later with
#   sudo grep -E 'SYMFONY__ENV__SECRET|ADMIN_PASSWORD' /srv/wallabag/.env
#
# ADMIN_PASSWORD rides .env into the container's environment so step 6 can
# change the password without the value crossing the host's process table or
# this script's output. That makes it readable via docker inspect, which is a
# deliberate trade: inspecting needs docker-group access, and Prompt Zero
# already calls that root-equivalent.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SYMFONY__ENV__DOMAIN_NAME=https://${DOMAIN_HOST}
		SYMFONY__ENV__SECRET=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-wallabag"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8109 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8109 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it, then close the credential the image ships with -------------
#
# The image creates its first account on first boot, a super admin whose
# username and password are both the word wallabag, documented in its README.
# The wait loop polls loopback rather than the public hostname so the password
# change happens as soon as the application answers at all.

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8109/api/info (first boot rebuilds the Symfony cache)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8109/api/info" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/api/info answered ${code:-nothing}. Check: docker compose logs --tail 40 wallabag"

docker compose exec -T wallabag su -c '/var/www/wallabag/bin/console fos:user:change-password wallabag "$ADMIN_PASSWORD" --env=prod' -s /bin/sh nobody >/dev/null

info="$(curl -sS "https://${DOMAIN_HOST}/api/info" || true)"
printf '%s\n' "$info" | grep -q '"version":"2.6.14"' \
	|| die "/api/info did not report version 2.6.14. Check: docker compose logs --tail 40 wallabag"
printf '%s\n' "$info" | grep -q '"allowed_registration":false' \
	|| die "/api/info reports registration is open. Stop and investigate before anyone finds this host."

# Public sign-up must bounce back to the login page rather than serve a form.
reg="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/register" || true)"
[ "$reg" = "301" ] || die "/register returned ${reg}, not 301. Stop and investigate."

curl -sS "https://${DOMAIN_HOST}/login" | grep -q 'Log in' \
	|| die "the login page did not contain 'Log in'. Check: docker compose logs --tail 40 wallabag"

# The credential from the README must no longer authenticate. A successful login
# lands on the unread list, whose HTML carries unread/list; a rejected one does
# not.
shipped=wallabag
jar="$(mktemp)"
tok="$(curl -sS -c "$jar" "https://${DOMAIN_HOST}/login" | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)"
[ -n "$tok" ] || die "could not read the login form's CSRF token, so the credential check could not run"
hits="$(curl -sS -b "$jar" -c "$jar" -L -d "_username=$shipped" -d "_password=$shipped" -d "_csrf_token=$tok" "https://${DOMAIN_HOST}/login_check" | grep -c 'unread/list' || true)"
rm -f "$jar"
[ "$hits" = "0" ] || die "the credential from the image README still logs in. Stop: this host is open to anyone."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/wallabag-${STAMP}.tar.gz" -C "$APP_DIR" data images compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/wallabag-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	wallabag is answering at https://${DOMAIN_HOST}/login

	  1. Log in as the user wallabag. Your password is in $APP_DIR/.env, mode
	     600, and it was not printed here. Read it with
	       sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager now. There is no outgoing mail on
	     this install, so there is no password-reset link to fall back on.
	  2. The credential from the image README no longer works, and /register
	     redirects to the login page. Both were checked, not assumed.
	  3. wallabag imports an Instapaper CSV export from its Import screen. The
	     export lives on the settings page of your Instapaper account.
	  4. First backup written to $APP_DIR/backups: one archive holding the
	     SQLite database, the images directory, compose.yml, .env and the Caddy
	     site block. It is on the same disk as the data, which is not a backup.
	     Copy it somewhere else tonight.
	  5. The container restarted for that backup, so give it two or three
	     minutes before the first page loads.

DONE
