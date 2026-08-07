#!/usr/bin/env bash
# XWiki · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=wiki.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/docker-library/official-images/blob/master/library/xwiki
#   https://github.com/xwiki/xwiki-docker/blob/master/17/postgres-tomcat/Dockerfile
#   https://github.com/xwiki/xwiki-docker/blob/master/17/postgres-tomcat/docker-compose.yml
#   https://github.com/xwiki/xwiki-docker/blob/master/17/postgres-tomcat/xwiki/docker-entrypoint.sh
#   https://github.com/xwiki/xwiki-docker/blob/master/17/postgres-tomcat/tomcat/setenv.sh
#
# One secret is generated here, on this machine: the PostgreSQL password. It
# goes into /srv/xwiki/.env with mode 600 and is never printed. There is no
# administrator password to generate, because XWiki seeds no account: the first
# one is registered by a human in the setup wizard, which is where this script
# stops and hands over.
#
# Read the closing summary. Between the moment this script starts the containers
# and the moment you register that account, anybody who reaches DOMAIN_HOST can
# register it instead, because XWiki offers its wizard to a signed-out visitor
# for as long as the wiki has no registered user.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/xwiki}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. wiki.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 3072 ] || die "only ${avail_mb} MB of RAM available; Tomcat's 1024 MB heap plus LibreOffice plus PostgreSQL wants 3072 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres and data both stay root-owned at 700. The PostgreSQL image chowns its
# own data directory and refuses one somebody claimed first, and the XWiki
# container's Tomcat runs as root, so data becomes root-owned the moment it
# boots. data is XWiki's permanent directory: the user interface the wizard
# downloads, the Solr index, the logs, and every attachment.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: the value is substituted into a JDBC connection string
# where punctuation helps nobody. Read it later with
#   sudo grep DB_PASSWORD /srv/xwiki/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-xwiki"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8172 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8172 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Tomcat boots and XWiki builds its entire schema in PostgreSQL before anything
# answers, so the first start is minutes and Caddy returns 502 for all of them.
# Ten minutes of patience is budgeted below. `/` redirects to /bin/view/Main/,
# which redirects again to the setup wizard, so curl follows two hops.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ (a first boot takes minutes)"
for _ in $(seq 1 60); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs --tail 60 xwiki"

curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'id="distributionWizard"' \
	|| die "the first page is not the setup wizard. Check: docker compose logs --tail 60 xwiki"

curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Distribution Wizard' \
	|| die "the wizard page did not render its Distribution Wizard heading"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U xwiki -d xwiki | gzip > "$APP_DIR/backups/xwiki-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/xwiki-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/xwiki-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/xwiki-files-${STAMP}.tar.gz" ] || die "the file archive is empty"

cat <<-DONE

	XWiki is answering at https://${DOMAIN_HOST}/ with its setup wizard.

	  1. Open https://${DOMAIN_HOST}/ in a browser now, not later. The first
	     screen is headed "Distribution Wizard". Its second step is headed
	     "Admin user": register the account you will administer this wiki
	     with, and put that password in your password manager as you type it.
	     No mail is configured, so there is no password-reset route.
	     Until that account exists, anyone who reaches this hostname can
	     register it instead of you.
	  2. Then let the "User Interface" step finish. It downloads the default
	     flavor from upstream's extension repository and takes minutes on a
	     progress bar that barely moves. That is the install working.
	  3. Then confirm the wizard closed behind you, from this server:
	       curl -sSL https://${DOMAIN_HOST}/bin/distribution/XWiki/Distribution \\
	         | grep -c 'id="distributionWizard"'
	     It must print 0.
	  4. The database password is in $APP_DIR/.env, mode 600, and was not
	     printed here. Read it with
	       sudo grep DB_PASSWORD $APP_DIR/.env
	  5. A first backup is in $APP_DIR/backups: a database dump and a file
	     archive holding compose.yml, .env, the permanent directory and the
	     live Caddy site block. Both were taken before the wizard ran, so run
	     the same two commands again once step 2 is done, then copy them off
	     this box. Attachments live on disk in that permanent directory, not
	     in the database, so a dump on its own is half a backup.

DONE
