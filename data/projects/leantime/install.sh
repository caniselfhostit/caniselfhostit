#!/usr/bin/env bash
# Leantime · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=plan.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.leantime.io/installation/docker
#   https://github.com/Leantime/docker-leantime/blob/master/sample.env
#   https://docs.leantime.io/installation/system-requirements
#   https://docs.leantime.io/installation/backup-restore
#
# Three secrets are generated here, on this machine: the MySQL root password,
# the MySQL password for the leantime database user, and LEAN_SESSION_PASSWORD,
# which salts every session cookie. All three go into /srv/leantime/.env with
# mode 600 and none is ever printed.
#
# DOMAIN_HOST is also LEAN_APP_URL, the base Leantime builds every redirect
# against, so it has to be the name you will actually use in a browser.
#
# This script stops one step short of a finished install on purpose: only a
# human can fill in the web installer at https://<DOMAIN_HOST>/install, which is
# where the first and only account is created. The summary at the end says so.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/leantime}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. plan.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP-FPM plus MySQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mysql stays root-owned: that image chowns its own data directory on first
# start and this script does not fight it. The two userfiles directories go to
# uid 1000, which is the www-data the application image runs as.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mysql"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/userfiles" "$APP_DIR/public-userfiles"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex for all three: Compose reads this file to expand the ${...} references in
# compose.yml and treats an unquoted # as the start of a comment, so a base64
# secret can lose its tail. Read them later with
#   sudo grep -E 'DB_PASSWORD|LEAN_SESSION_PASSWORD' /srv/leantime/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DOMAIN_NAME=${DOMAIN_HOST}
		DB_ROOT_PASSWORD=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		LEAN_SESSION_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-leantime"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8163 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8163 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MySQL initialises its data directory, then the application container starts,
# because compose holds it back until the database reports healthy. Everything
# answers 502 through Caddy until both are up, which is expected.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthCheck.php"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthCheck.php" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/healthCheck.php answered ${code:-nothing}. Check: docker compose logs --tail 40 leantime"

curl -sS "https://${DOMAIN_HOST}/healthCheck.php" | grep -q '^Ok$' \
	|| die "/healthCheck.php answered 200 without printing Ok. Check: docker compose logs --tail 40 leantime"

# The web installer has to be reachable and unfinished, or the account this
# install depends on cannot be created. A miss here is usually LEAN_APP_URL in
# .env disagreeing with the hostname in the Caddy site block.
curl -sS "https://${DOMAIN_HOST}/install" | grep -q 'This script will set up your database' \
	|| die "https://${DOMAIN_HOST}/install did not serve the installer. Compare DOMAIN_NAME in $APP_DIR/.env with the site block in /etc/caddy/Caddyfile."

# --- 7. The first backup, before day one ends --------------------------------
#
# Taken now, while the database is empty, so the restore path is proven before
# it holds anything. Run it again after the account exists.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T leantime_db sh -c 'mysqldump --single-transaction --no-tablespaces -u leantime -p"$MYSQL_PASSWORD" leantime' \
	| gzip > "$APP_DIR/backups/leantime-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/leantime-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env userfiles public-userfiles -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/leantime-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Leantime is answering at https://${DOMAIN_HOST}/healthCheck.php

	  1. Finish the install in a browser. Only you can do this step:
	       open https://${DOMAIN_HOST}/install
	     Fill in your email, first name, last name and company, press Install,
	     then set a password on the Setting Account Details screen that follows.
	     Upstream wants 8 characters with an uppercase, a lowercase, a number
	     and a symbol. Put it in your password manager: nothing on this server
	     can mail it back to you, and this is the only account that exists.
	  2. Then prove the installer closed behind you. Both of these must hold:
	       curl -sS https://${DOMAIN_HOST}/install | grep -c 'This script will set up your database'
	     must print 0, and
	       curl -sSL https://${DOMAIN_HOST}/ | grep -c '<label for="password">Password</label>'
	     must print 1. A 1 from the first means no account was created and the
	     install form is still open on a public hostname. Go back to step 1.
	  3. Your three secrets are in $APP_DIR/.env, mode 600. They were not
	     printed here. LEAN_SESSION_PASSWORD is in that file and nowhere else,
	     so a database dump restored without it signs everybody out.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding compose.yml, .env, both userfiles directories and the
	     Caddy site block. The dump was taken before your account existed, so
	     run the two commands in step 8 of the prompt again tonight. They are on
	     the same disk as the data, which is not a backup. Copy them off the box.

DONE
