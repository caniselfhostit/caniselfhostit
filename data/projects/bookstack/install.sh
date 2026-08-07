#!/usr/bin/env bash
# BookStack · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=wiki.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.bookstackapp.com/docs/admin/installation/
#   https://github.com/BookStackApp/BookStack/blob/v26.05.3/.env.example.complete
#   https://docs.linuxserver.io/images/docker-bookstack/
#   https://www.bookstackapp.com/docs/admin/commands/
#
# BookStack publishes no Docker image; its installation page points at community
# docker setups, and this uses the LinuxServer.io one pinned by digest.
#
# Four secrets are generated here, on this machine: the application key, the
# database password, the MariaDB root password and the administrator's password.
# All four go into /srv/bookstack/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST is also APP_URL, the value BookStack builds every stored link
# from. Choose it once; changing it later is a database rewrite.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/bookstack}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. wiki.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the administrator will sign in with"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; PHP plus MariaDB wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb stays root-owned at 700: the MariaDB image chowns its own data
# directory and refuses one somebody claimed first.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/config"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# APP_KEY is 32 random bytes in the base64: form BookStack's own key generator
# emits. Read the administrator password later with
#   sudo grep ADMIN_PASSWORD /srv/bookstack/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		ADMIN_EMAIL=${ADMIN_EMAIL}
		APP_KEY=base64:$(openssl rand -base64 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> "$APP_DIR/.env"
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-bookstack"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8150 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8150 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The image runs BookStack's schema migration on the way up, and that migration
# is what seeds the admin@admin.com account this script then replaces.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/status"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/status" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/status answered ${code:-nothing}. Check: docker compose logs --tail 40 bookstack"

curl -sS "https://${DOMAIN_HOST}/status" | grep -q '"database":true' \
	|| die "/status answered 200 without a healthy database. Check: docker compose logs --tail 40 bookstack"

# Replace the account the first migration seeds. --initial rewrites the name,
# email and password of admin@admin.com in place rather than adding a second
# administrator. Both values come from the container environment, so neither
# reaches this machine's process list. They stay in that environment after,
# where `docker inspect bookstack` can read them: the same boundary as .env
# itself, since the docker group is root-equivalent on this box.
admin_out="$(docker compose exec -T --user abc bookstack sh -c 'php /app/www/artisan bookstack:create-admin --initial --no-ansi --name="Site administrator" --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD"')"
printf '%s' "$admin_out" | grep -q 'The default admin user has been updated with the provided details!' \
	|| die "the console command did not report updating the default admin user. Stop and investigate."
unset admin_out

curl -sS "https://${DOMAIN_HOST}/login" | grep -q 'list-heading">Log In<' \
	|| die "the login page did not render its Log In heading"

# The shipped credential must now be refused. A rejected sign-in renders
# BookStack's own wording for bad credentials.
shipped=password
jar="$(mktemp)"
tok="$(curl -sS -c "$jar" "https://${DOMAIN_HOST}/login" | sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' | head -1)"
[ -n "$tok" ] || die "no CSRF token on the login page, so the credential check would prove nothing"
curl -sS -b "$jar" -c "$jar" -L -d "_token=$tok" -d "email=admin@admin.com" -d "password=$shipped" "https://${DOMAIN_HOST}/login" \
	| grep -q 'These credentials do not match our records' \
	|| die "the shipped admin credential still works. Stop: this install is not safe to leave running."
rm -f "$jar"
unset shipped tok

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/bookstack-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/bookstack-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env config -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/bookstack-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/bookstack-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	BookStack is answering at https://${DOMAIN_HOST}/login

	  1. The account BookStack's first migration seeds, admin@admin.com with a
	     published password, has been replaced by ${ADMIN_EMAIL}, and a sign-in
	     attempt with the old pair was checked and refused.
	  2. Your password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and this
	     install configures no mail, so there is no password-reset route.
	  3. APP_KEY in that same file encrypts what BookStack stores encrypted.
	     A restore without it is a restore of unreadable rows.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive holding compose.yml, .env, the uploads under config/ and the
	     live Caddy site block. They are on the same disk as the data, which is
	     not a backup. Copy them somewhere else tonight.

DONE
