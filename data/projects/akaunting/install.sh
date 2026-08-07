#!/usr/bin/env bash
# Akaunting · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=books.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/akaunting/docker/blob/master/README.md
#   https://github.com/akaunting/docker/blob/master/files/akaunting.sh
#   https://github.com/akaunting/docker/blob/master/env/run.env.example
#   https://akaunting.com/hc/docs/on-premise/requirements/
#
# Three secrets are generated here, on this machine: the MariaDB password for the
# akaunting database user, the MariaDB root password, and the password put on the
# first account. All three go into /srv/akaunting/.env with mode 600 and none of
# them is ever printed.
#
# Akaunting is source-available, not open source. Its licence grants free
# production use for up to two users, one company and one thousand invoices.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/akaunting}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. books.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the first account signs in with"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PHP under Apache plus MariaDB wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No directory for the application: the image ships Akaunting inside
# /var/www/html and compose keeps that path in a named volume.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Read them later with
#   grep -E 'DB_PASSWORD|ADMIN_PASSWORD' /srv/akaunting/.env
# AKAUNTING_SETUP makes the container run `php artisan install` once. Step 6
# removes it so a later restart cannot run the installer a second time.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		LOCALE=en-US
		COMPANY_NAME=My Company
		COMPANY_EMAIL=${ADMIN_EMAIL}
		ADMIN_EMAIL=${ADMIN_EMAIL}
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -base64 24)
		AKAUNTING_SETUP=true
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-akaunting"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8151 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8151 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MariaDB initialises, then the entrypoint runs the installer: it writes the
# application's own .env inside the volume with a fresh APP_KEY, builds the
# schema, and creates the company and the account. Apache starts after that.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/auth/login"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/auth/login" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/auth/login answered ${code:-nothing}. Check: docker compose logs --tail 60 akaunting"

curl -sS "https://${DOMAIN_HOST}/auth/login" | grep -q 'Login to start your session' \
	|| die "the login page did not contain 'Login to start your session'. Check: docker compose logs --tail 60 akaunting"

created="$(docker compose logs akaunting | grep -c 'Creating admin' || true)"
[ "$created" = "1" ] || die "the installer created ${created} accounts, not 1. Stop and read: docker compose logs --tail 60 akaunting"

# Close the bootstrap: without AKAUNTING_SETUP the entrypoint starts Apache and
# nothing else, so no restart can build a second company or a second account.
sed -i -e '/^AKAUNTING_SETUP/d' "$APP_DIR/.env"
docker compose up -d --force-recreate akaunting
sleep 45
again="$(docker compose logs akaunting | grep -c 'Creating admin' || true)"
[ "$again" = "0" ] || die "the installer ran again after AKAUNTING_SETUP was removed. Stop and investigate."
code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/auth/login" || true)"
[ "$code" = "200" ] || die "/auth/login answered ${code} after the restart"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --no-tablespaces -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/akaunting-db-${STAMP}.sql.gz"
docker compose exec -T akaunting tar -C /var/www/html -czf - .env storage modules > "$APP_DIR/backups/akaunting-app-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/akaunting-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/akaunting-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/akaunting-app-${STAMP}.tar.gz" ] || die "the application archive is empty"

cat <<-DONE

	Akaunting is answering at https://${DOMAIN_HOST}/auth/login

	  1. Your password is in $APP_DIR/.env, mode 600. Read it with
	       grep ADMIN_PASSWORD $APP_DIR/.env
	     put it in your password manager, and sign in as ${ADMIN_EMAIL}.
	     It was not printed here. Nothing on this install sends mail, so
	     there is no reset link: that password manager entry is the plan.
	     Once it is saved, take the line off the server:
	       sed -i '/^ADMIN_PASSWORD/d' $APP_DIR/.env
	  2. Rename the company under Settings. Every invoice carries that name,
	     and it currently reads My Company.
	  3. The licence grants free production use for up to two users, one
	     company and one thousand invoices. The double-entry ledger, bank
	     feeds and inventory are separate paid apps from akaunting.com.
	  4. First backup written to $APP_DIR/backups: a database dump, an
	     application archive holding the volume's .env and attachments, and a
	     config archive. They are on the same disk as the data, which is not
	     a backup. Copy all three somewhere else tonight.

DONE
