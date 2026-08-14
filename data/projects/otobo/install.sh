#!/usr/bin/env bash
# OTOBO · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=desk.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://doc.otobo.org/manual/installation/11.0/en/content/installation/installation-docker.html
#   https://doc.otobo.org/manual/installation/11.0/en/content/requirements.html
#   https://github.com/RotherOSS/otobo-docker/blob/rel-11_0_17/docker-compose/otobo-base.yml
#   https://github.com/RotherOSS/otobo/blob/rel-11_0_17/bin/docker/entrypoint.sh
#
# One secret is generated here, on this machine: OTOBO_DB_ROOT_PASSWORD, the
# MariaDB root password. It goes into /srv/otobo/.env with mode 600 and is
# never printed. You type it once, into the installer, in a browser.
#
# This script cannot finish the install, because only a browser can run
# installer.pl. It stops with that installer still open and tells you to go and
# claim it. Until you do, whoever loads the hostname first owns the system: the
# installer is not a signup form, it creates the schema and sets the
# administrator password.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/otobo}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. desk.example.com"
case "$DOMAIN_HOST" in
	*/*) die "DOMAIN_HOST is a hostname, not a URL: no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this machine is ${arch}; upstream publishes rotheross/otobo for amd64 only"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; this stack wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Three owners, on purpose. The OTOBO image runs as uid 1000 and copies its
# whole application tree into otobo/ on first start, so it owns that outright.
# The MariaDB image takes its own data directory the first time it starts, so
# that one is left to root.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/otobo"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: you retype this into the installer's database form,
# and OTOBO carries it into a CREATE USER statement. Read it later with
#   sudo grep OTOBO_DB_ROOT_PASSWORD /srv/otobo/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		OTOBO_DB_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-otobo"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8202, 3306 or 6379 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8202, 3306 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start copies roughly a gigabyte of application tree out of the image
# into otobo/ before anything listens on 5000, so the wait is generous.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
code=""
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "$code" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 web"

# /health is a static file, so that 200 proves Perl is listening and nothing
# about the database. The installer page is the real first screen.
if ! curl -sSL "https://${DOMAIN_HOST}/otobo/installer.pl" | grep -q 'Welcome to OTOBO'; then
	die "https://${DOMAIN_HOST}/otobo/installer.pl is not showing the installer. Check: docker compose logs --tail 40 web"
fi

docker compose ps --format '{{.Service}} {{.State}} {{.Health}}'

# --- 7. The first backup, before day one ends --------------------------------
#
# Nothing is stopped: --single-transaction snapshots InnoDB consistently, and
# the root password is read from the database container's own environment. The
# otobo database does not exist until you finish the installer, so this dumps
# every database rather than a schema that is not there yet, and proves both
# commands work while there is nothing to lose.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --max-allowed-packet=136314880 -u root -p"$MARIADB_ROOT_PASSWORD" --all-databases' | gzip > "$APP_DIR/backups/otobo-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/otobo-config-${STAMP}.tar.gz" --exclude=var/tmp -C "$APP_DIR" compose.yml .env -C "$APP_DIR/otobo" Kernel/Config.pm var -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/otobo-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/otobo-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	OTOBO is answering at https://${DOMAIN_HOST}

	  1. Do this now, before anything else: open
	       https://${DOMAIN_HOST}/otobo/installer.pl
	     and work through its four steps. That installer is not a signup form,
	     it is the whole system, and it answers whoever loads the hostname
	     first. Choose MySQL and "Create a new database for OTOBO"; User root,
	     Host db, Database name otobo, and for the password run
	       sudo grep OTOBO_DB_ROOT_PASSWORD $APP_DIR/.env
	     Leave the generated OTOBO database password alone. Set HTTP Type to
	     https and System FQDN to ${DOMAIN_HOST}. Skip the mail step. The last
	     page prints root@localhost and a password, shown once: put it in your
	     password manager before you close the tab.
	  2. Then prove the doors are shut and the clocks are running:
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/otobo/installer.pl
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/otobo/migration.pl
	       cd $APP_DIR && docker compose exec -T web bin/otobo.Console.pl Admin::Config::Update --setting-name CustomerPanelCreateAccount --value 0
	       docker compose restart web && sleep 45
	       curl -sSL https://${DOMAIN_HOST}/otobo/customer.pl | grep -c 'oooRegister'
	       docker compose ps --format '{{.Service}} {{.Health}}' | grep daemon
	     Expect 403, 403, Done, 0, and daemon healthy. The last one matters
	     most: an unhealthy daemon means no escalation clock ever fires.
	  3. Your MariaDB root password is in $APP_DIR/.env, mode 600. It was not
	     printed here. Put it in your password manager too.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight, and
	     take a fresh pair once the installer has created the schema.

DONE
