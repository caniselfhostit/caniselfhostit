#!/usr/bin/env bash
# OrangeHRM Starter · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=hr.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream packaging:
#   https://github.com/orangehrm/orangehrm/blob/v5.9/Dockerfile
#   https://github.com/orangehrm/orangehrm/blob/v5.9/installer/config/routes.yaml
#   https://github.com/orangehrm/orangehrm/blob/v5.9/installer/config/system_requirements.php
#   https://github.com/orangehrm/orangehrm/blob/v5.9/installer/client/src/pages/DatabaseConfigScreen.vue
#
# Two secrets are generated here, on this machine: the MariaDB root password and
# the password of the orangehrm database user. Both go into /srv/orangehrm/.env
# with mode 600 and neither is ever printed. You will need the second one: the
# browser installer asks you to type it in.
#
# This script cannot finish the install, because only a browser can. OrangeHRM
# 5.9 has no environment variables and no scriptable installer: its command line
# installer refuses non interactive mode outright. The script stops with the
# setup wizard open and tells you to go and claim it. Until you do, whoever
# loads the hostname first is looking at your setup wizard.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/orangehrm}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------
#
# amd64 is a hard gate, not a preference. The 5.9 tag on Docker Hub publishes a
# single manifest and it is linux/amd64.

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. hr.example.com"
case "$DOMAIN_HOST" in
	*/*) die "DOMAIN_HOST is a hostname, not a URL: no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this server is ${arch}; orangehrm/orangehrm:5.9 publishes linux/amd64 only. Use an amd64 server."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP-Apache plus MariaDB wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb is mode 700 and left to root because the MariaDB image chowns its own
# data directory on first start. The application has no directory here at all:
# it lives in a named Docker volume, because its image declares /var/www/html as
# a VOLUME and an empty bind mount there would hide the application.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both. These values are read back by Compose out of
# .env, where a `$` would be interpolated and a `#` would start a comment, and
# one of them gets typed into a browser field by a human. Read them later with
#   sudo grep -E 'DB_PASSWORD|MARIADB_ROOT_PASSWORD' /srv/orangehrm/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DB_PASSWORD=$(openssl rand -hex 24)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-orangehrm"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8194 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8194 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MariaDB initialises an empty orangehrm database and its user on first start,
# which is the `Existing Empty Database` the wizard is about to be pointed at.
# Nothing else happens until a human opens a browser.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 30); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs --tail 40 orangehrm"

# The root of an uninstalled OrangeHRM redirects into the installer, which
# renders a Vue page whose server-side markup carries the component name. Its
# absence means either Caddy is reaching something else or a previous run has
# already been claimed.
curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'welcome-screen' \
	|| die "https://${DOMAIN_HOST}/ is not showing the setup wizard. If someone already finished it, treat this box as compromised and rebuild."

# The database has to be reachable from the application container under the
# hostname the wizard will be given, or the wizard cannot get past screen three.
docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$MARIADB_DATABASE"' >/dev/null \
	|| die "the orangehrm database user cannot log in. Check: docker compose logs --tail 40 mariadb"

# --- 7. The first backup, of what exists right now ---------------------------
#
# There is no database dump yet, because there is no schema yet: the wizard
# writes it. What exists and cannot be regenerated is .env, and the archive
# below is the only copy of it that is not on the live disk.

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/orangehrm-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/orangehrm-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	OrangeHRM Starter 5.9 is answering at https://${DOMAIN_HOST}

	  1. Do this now, before anything else: open
	       https://${DOMAIN_HOST}/
	     and complete the setup wizard. Until you do, that is a setup wizard for
	     whoever loads the hostname first. Once one install finishes, the
	     installer answers 502 to every screen and can never be run again.
	  2. On the Database Configuration screen choose "Existing Empty Database",
	     then enter host mariadb, port 3306, database orangehrm, user orangehrm,
	     and the password from
	       sudo grep DB_PASSWORD $APP_DIR/.env
	     Leave "Enable Data Encryption" unticked: it writes a key file that every
	     backup then has to carry or the encrypted columns are unreadable.
	  3. On the Admin User screen, untick the box that offers to register your
	     system with OrangeHRM. Ticked, it posts your name, email, phone number,
	     organisation name and a profile of this server to OrangeHRM. It is
	     ticked by default. Your admin password needs 8 characters, no spaces,
	     and a lower-case letter, an upper-case letter, a digit and a symbol.
	  4. When the wizard says it is done, prove the installer is shut:
	       curl -sS -o /dev/null -w '%{http_code}' 'https://${DOMAIN_HOST}/installer/index.php/installer/database-config'; echo
	     That prints 502: upstream refuses every installer screen once the
	     configuration file exists. Anything else means the wizard did not
	     finish and the hostname is still claimable. Then take the real
	     backup, which this script could not:
	       cd $APP_DIR
	       docker compose exec -T mariadb sh -c 'exec mariadb-dump -u"\$MARIADB_USER" -p"\$MARIADB_PASSWORD" --single-transaction "\$MARIADB_DATABASE"' | gzip > backups/orangehrm-db-\$(date +%F).sql.gz
	       docker compose exec -T orangehrm tar -C /var/www/html -czf - lib/confs > backups/orangehrm-confs-\$(date +%F).tar.gz
	  5. Backups are on the same disk as the data, which is not a backup. Copy
	     them somewhere else tonight.

DONE
