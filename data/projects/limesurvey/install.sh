#!/usr/bin/env bash
# LimeSurvey · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=survey.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.limesurvey.org/manual/Installation_-_LimeSurvey_CE
#   https://www.limesurvey.org/manual/Optional_settings
#   https://www.limesurvey.org/manual/Data_encryption
#   https://github.com/martialblog/docker-limesurvey/blob/7.0.7-260729/README.md
#   https://github.com/martialblog/docker-limesurvey/blob/7.0.7-260729/7.0/apache/entrypoint.sh
#
# The LimeSurvey project publishes no Docker image. martialblog/limesurvey is a
# community image, MIT, maintained outside that project; its Dockerfile fetches
# the official LimeSurvey 7.0.7+260729 tarball and checks its sha256.
#
# Five secrets are generated here, on this machine: the limesurvey database
# password, the MariaDB root password, the administrator's password, and the two
# data-encryption values. All five go into /srv/limesurvey/.env with mode 600 and
# none is ever printed. Change either encryption value later and encrypted
# participant records stop decrypting, with no recovery path.
#
# DOMAIN_HOST is also HOST_INFO, the address inside every survey link you send.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/limesurvey}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. survey.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address for the administrator account"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; PHP and MariaDB want 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb stays owned by root: the MariaDB image chowns its own data directory
# and refuses one somebody claimed first. LimeSurvey's upload tree is a named
# volume, because the image ships that directory's base content and an empty
# host folder mounted over it would hide the themes and plugins in it.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the five secrets, on the server -----------------------------
#
# Hex for the three that travel inside connection strings and config files,
# base64 for the one a human types into a login form. Read them later with
#   sudo grep -E 'DB_PASSWORD|ADMIN_PASSWORD' /srv/limesurvey/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		HOST_INFO=https://${DOMAIN_HOST}
		ADMIN_EMAIL=${ADMIN_EMAIL}
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -base64 24)
		ENCRYPT_NONCE=$(openssl rand -hex 24)
		ENCRYPT_SECRET_BOX_KEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-limesurvey"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8130 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8130 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The entrypoint waits for MariaDB, writes application/config/config.php and
# application/config/security.php, then asks an empty database whether it has
# been migrated. That question fails with a PHP stack trace on purpose, and the
# console installer runs next. The stack trace is not the error.

docker compose pull
docker compose up -d

LOGIN_URL="https://${DOMAIN_HOST}/index.php/admin/authentication/sa/login"
echo "==> waiting for ${LOGIN_URL}"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "$LOGIN_URL" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the login page answered ${code:-nothing}. Check: docker compose logs --tail 60 app"

curl -sS "$LOGIN_URL" | grep -q 'x-test id="action::login"' \
	|| die "that page answered 200 without the LimeSurvey login form. Check: docker compose logs --tail 60 app"

# The browser installer must refuse everyone now that a config file exists.
curl -sS "https://${DOMAIN_HOST}/index.php/installer" | grep -q 'Installation has been done already' \
	|| die "the installer did not report itself disabled. Stop and investigate before anyone finds that URL."

# Absolute links have to carry https and this hostname, or invitations will not.
docker compose exec -T app grep -q "'hostInfo' => 'https://${DOMAIN_HOST}'" application/config/config.php \
	|| die "config.php does not name https://${DOMAIN_HOST} as hostInfo"

# One administrator, made by the console installer rather than by a public form.
users="$(docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from lime_users" "$MARIADB_DATABASE"' | tr -dc '0-9')"
[ "${users:-0}" -ge 1 ] || die "the users table is empty, so the console installer did not run"

# --- 7. The first backup, before day one ends --------------------------------
#
# Taken now, with an empty LimeSurvey, so the restore path is proved before there
# is anything to lose. The config archive carries the live Caddy site block, not
# the <DOMAIN> template, and the .env the encryption keys live in.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/limesurvey-db-${STAMP}.sql.gz"
docker compose exec -T app tar -C /var/www/html -czf - upload > "$APP_DIR/backups/limesurvey-upload-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/limesurvey-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/limesurvey-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/limesurvey-upload-${STAMP}.tar.gz" ] || die "the upload archive is empty"
[ -s "$APP_DIR/backups/limesurvey-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	LimeSurvey is answering at https://${DOMAIN_HOST}/index.php/admin

	  1. Sign in as the user "admin". The password is in $APP_DIR/.env, mode 600.
	     Read it with
	       sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here. Changing
	     that line afterwards does nothing: it seeded the account once, and the
	     password now lives in the database and moves in the profile screen.
	  2. The browser installer is already disabled, and this script checked it:
	       curl -sS 'https://${DOMAIN_HOST}/index.php/installer'
	     answers with "Installation has been done already. Installer disabled."
	  3. Keep $APP_DIR/.env. ENCRYPT_NONCE and ENCRYPT_SECRET_BOX_KEY are written
	     into the container's security.php at every start, so they are how
	     encrypted participant data is read back. Lose them and it is gone.
	  4. First backup written to $APP_DIR/backups: a database dump, the upload
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy them off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/limesurvey/
	  5. No mail is configured. Anonymous link surveys work; invitations,
	     reminders and password resets need SMTP, which this install does not set.

DONE
