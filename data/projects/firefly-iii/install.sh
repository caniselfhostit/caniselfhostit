#!/usr/bin/env bash
# Firefly III · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=money.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.firefly-iii.org/how-to/firefly-iii/installation/docker/
#   https://github.com/firefly-iii/firefly-iii/blob/v6.6.6/.env.example
#   https://docs.firefly-iii.org/how-to/firefly-iii/advanced/cron/
#   https://docs.firefly-iii.org/how-to/firefly-iii/advanced/backup/
#
# Three secrets are generated here, on this machine: the Laravel application
# key, the MariaDB password, and the static cron token. All three go into
# /srv/firefly-iii/.env with mode 600 and none of them is ever printed.
#
# DOMAIN_HOST is also APP_URL, the address Firefly III builds every link and
# form action from. It has to be the hostname you pointed at this box.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/firefly-iii}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. money.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP plus MariaDB wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb stays owned by root: the MariaDB image chowns its own data directory
# the first time it starts. upload is the opposite case, because the Firefly III
# image runs as www-data (uid 33) and never chowns a mount.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mariadb"
sudo install -d -m 750 -o 33 -g 33 "$APP_DIR/upload"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex for all three: upstream documents APP_KEY and STATIC_CRON_TOKEN as exactly
# 32 characters with special characters avoided, and `openssl rand -hex 16` is
# 32 characters of 0-9a-f. Read them later with
#   sudo grep -E 'APP_KEY|DB_PASSWORD|STATIC_CRON_TOKEN' /srv/firefly-iii/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		TZ=UTC
		TRUSTED_PROXIES=**
		APP_KEY=$(openssl rand -hex 16)
		DB_PASSWORD=$(openssl rand -hex 32)
		STATIC_CRON_TOKEN=$(openssl rand -hex 16)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

key_len="$(awk -F= '/^APP_KEY=/{print length($2)}' "$APP_DIR/.env")"
[ "$key_len" = "32" ] || die "APP_KEY is ${key_len} characters, not 32. Firefly III will not boot."

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-firefly-iii"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8155 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8155 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Firefly III builds its schema on the way up. On an empty database that is a
# minute or two during which every page answers 500.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 app"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '^OK' \
	|| die "/health answered 200 without OK. Check: docker compose logs --tail 40 app"

# The first screen a human sees. Upstream renders this heading on /login.
curl -sS "https://${DOMAIN_HOST}/login" | grep -q 'Sign in to start your session' \
	|| die "the login page did not carry 'Sign in to start your session'. Check the Caddy site block."

# The cron container has to reach the app and be accepted, or recurring
# transactions and auto-budgets silently never run.
docker compose exec -T cron sh -c 'wget -qO- http://app:8080/api/v1/cron/$STATIC_CRON_TOKEN' \
	| grep -q '"job_fired":true' \
	|| die "the cron endpoint did not report job_fired. Check: docker compose logs --tail 20 cron"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump -ufirefly -p"$MARIADB_PASSWORD" --single-transaction firefly' \
	| gzip > "$APP_DIR/backups/firefly-iii-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/firefly-iii-upload-${STAMP}.tar.gz" -C "$APP_DIR" upload
sudo tar -czf "$APP_DIR/backups/firefly-iii-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/firefly-iii-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Firefly III is answering at https://${DOMAIN_HOST}/health

	  1. Open https://${DOMAIN_HOST}/register and create the first account now.
	     Firefly III runs in single-user mode, so registration is open until one
	     account exists and closes itself afterwards. Confirm that it closed:
	       curl -sS https://${DOMAIN_HOST}/register | grep -c 'Registration is currently not available'
	     That has to print 1 before you call this install finished.
	  2. There is no password reset, because this install sends no mail. Put the
	     password you chose in your password manager now.
	  3. Your three secrets are in $APP_DIR/.env, mode 600, and none was printed
	     here. APP_KEY is the one you cannot lose: a database restored without it
	     is a ledger nobody can read.
	  4. No bank connection. Transactions arrive as CSV files you export from
	     your bank and import, or through the separate Firefly III Data Importer,
	     which this script does not install.
	  5. First backup written to $APP_DIR/backups: a database dump, the upload
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight.

DONE
