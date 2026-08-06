#!/usr/bin/env bash
# listmonk · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=news.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://listmonk.app/docs/installation/
#   https://listmonk.app/docs/configuration/
#   https://listmonk.app/docs/upgrade/
#   https://github.com/knadh/listmonk/blob/v6.2.0/cmd/handlers.go
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the Super Admin password. Both go into /srv/listmonk/.env with mode 600 and
# neither is ever printed.
#
# This script stops where a human has to take over. listmonk cannot send mail
# until you enter an SMTP relay's host, port, username and password in
# Settings -> SMTP, and it will put http://localhost:9000 inside every campaign
# until you set the Root URL in Settings -> General. Both are browser steps and
# the closing summary spells them out.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/listmonk}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. news.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; listmonk plus PostgreSQL wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 755 "$APP_DIR/uploads"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex for the database password, which travels inside a connection string, and
# base64 for the Super Admin password, which a human pastes into a login form.
# Upstream reads LISTMONK_ADMIN_USER and LISTMONK_ADMIN_PASSWORD during the
# one-time install pass, so the account exists before the login page is ever
# public. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|LISTMONK_ADMIN_PASSWORD' /srv/listmonk/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		LISTMONK_ADMIN_USER=admin
		LISTMONK_ADMIN_PASSWORD=$(openssl rand -base64 30)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-listmonk"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8096 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8096 and 5432 stay closed"
	echo "==> nothing opens for mail: the relay connection is outbound"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The compose command runs upstream's three phases in order: install the schema
# once on an empty database, apply migrations, then serve.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 app"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"data":true' \
	|| die "/health answered 200 without data true. Check: docker compose logs --tail 40 app"

# The first screen. `New user` in place of `Login` means the database was not
# empty on first start, so the Super Admin from step 3 was never created.
curl -sS "https://${DOMAIN_HOST}/admin/login" | grep -q '<h2>Login</h2>' \
	|| die "the login page did not show the Login heading. If it shows 'New user', the database was not empty: docker compose down; sudo rm -rf ${APP_DIR}/postgres; re-run this script."

# The admin API must refuse an unauthenticated call. Upstream returns 403 for a
# missing or invalid session.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/lists" || true)"
[ "$unauth" = "403" ] || die "an unauthenticated API call returned ${unauth}, not 403. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U listmonk -d listmonk | gzip > "$APP_DIR/backups/listmonk-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/listmonk-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/listmonk-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	listmonk is answering at https://${DOMAIN_HOST}/admin/login

	  1. Your Super Admin username is admin. The password is in $APP_DIR/.env,
	     mode 600. Read it with
	       sudo grep LISTMONK_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. This install cannot send yet, and that is the part only you can finish.
	     Log in, then:
	       Settings -> General : set Root URL to https://${DOMAIN_HOST}. It ships
	         as http://localhost:9000, and every unsubscribe link, archive URL
	         and tracking pixel in a campaign is built from it.
	       Settings -> General : set the default from-address to one on a domain
	         you control. It ships as an example address.
	       Settings -> SMTP    : the seeded first entry is switched on and points
	         at smtp.yoursite.com with placeholder credentials. Replace its host,
	         port, username and password with your relay's, and press Test
	         connection before saving.
	  3. Confirm those landed, from this machine:
	       cd $APP_DIR && docker compose exec -T db psql -U listmonk -d listmonk -tAc "SELECT key, value FROM settings WHERE key IN ('app.root_url', 'app.from_email')"
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. Both carry live credentials, and both are on the same disk as
	     the data, which is not a backup. Copy them somewhere else tonight.
	  5. Send one campaign to a list holding only your own address before you
	     import anybody else's. When nothing arrives, read Settings -> Logs.

DONE
