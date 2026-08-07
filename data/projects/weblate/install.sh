#!/usr/bin/env bash
# Weblate · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=weblate.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.weblate.org/en/latest/admin/install/docker.html
#   https://docs.weblate.org/en/latest/admin/install.html
#   https://docs.weblate.org/en/latest/vcs.html
#   https://caddyserver.com/docs/automatic-https
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the first password on the admin account. Both go into /srv/weblate/.env with
# mode 600 and neither is ever printed.
#
# DOMAIN_HOST is also WEBLATE_SITE_DOMAIN. Weblate builds every link it prints
# out of it, so choose the hostname you intend to keep.
#
# This script stops short of one thing on purpose: only a human at a browser can
# sign in for the first time, and the closing summary says how to do that and
# how to take the admin password back out of the configuration afterwards.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/weblate}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. weblate.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address you want on the administrator account"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 3072 ] || die "only ${avail_mb} MB of RAM available; upstream states 3 GB for Weblate, its database and a web server"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Three owners, three reasons. The Weblate image runs as uid 1000 and exits with
# a message about /app/data when it cannot write there, so data and cache are
# handed to that uid. The PostgreSQL and Valkey images each chown their own data
# directory at start-up, so those two stay root-owned and untouched.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/data" "$APP_DIR/cache"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/valkey"
rendered="$(mktemp)"
sed -e "s|<DOMAIN>|${DOMAIN_HOST}|g" -e "s|<ADMIN_EMAIL>|${ADMIN_EMAIL}|g" \
	"$(dirname "$0")/compose.yml" > "$rendered"
install -m 0644 "$rendered" "$APP_DIR/compose.yml"
rm -f "$rendered"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex for the database password because it is interpolated into a connection
# string. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|WEBLATE_ADMIN_PASSWORD' /srv/weblate/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		WEBLATE_ADMIN_PASSWORD=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-weblate"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8173, 5432 or 6379 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8173, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start migrates the database and collects static files behind a web
# server that is not listening yet, which is why the image carries a five-minute
# health-check start period and why this loop waits ten.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthz/ (this takes minutes on a first boot)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthz/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/healthz/ answered ${code:-nothing}. Check: docker compose logs --tail 40 weblate"

curl -sS "https://${DOMAIN_HOST}/healthz/" | grep -qx 'ok' \
	|| die "/healthz/ answered 200 without the body ok. Check: docker compose logs --tail 40 weblate"

login="$(curl -sS "https://${DOMAIN_HOST}/accounts/login/" || true)"
printf '%s' "$login" | grep -q 'Sign in @ Weblate' \
	|| die "the sign-in page is not Weblate's. Check: docker compose logs --tail 40 weblate"

# The security assert: with registration closed there is no register link, so
# nobody who finds this hostname can create an account.
if printf '%s' "$login" | grep -q 'Register new account'; then
	die "the sign-in page still offers Register new account. WEBLATE_REGISTRATION_OPEN did not reach the container."
fi

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U weblate -d weblate | gzip > "$APP_DIR/backups/weblate-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/weblate-files-${STAMP}.tar.gz" -C "$APP_DIR" data compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/weblate-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Weblate is answering at https://${DOMAIN_HOST}/healthz/

	  1. Open https://${DOMAIN_HOST}/accounts/login/ in a browser. The first
	     screen reads "Sign in to Weblate" and carries no register link,
	     because registration is closed. Sign in as the username admin.
	     Read the password yourself, on this server, with
	       sudo grep WEBLATE_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Then take that line out of the configuration, because while it is
	     there Weblate resets the account to it on every container start:
	       sudo sed -i '/^WEBLATE_ADMIN_PASSWORD/d' $APP_DIR/.env
	       cd $APP_DIR && docker compose up -d --force-recreate weblate
	     Putting it back with a new value is how you reset a lost password.
	  3. Next comes the part this script cannot do. Weblate pushes
	     translations back to your git repositories, and that needs a key it
	     generates for itself at https://${DOMAIN_HOST}/manage/ssh/ whose
	     public half you add on your code host with write access. Add people
	     from the same Manage section: the invitation link is copyable, so no
	     mail server is involved.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding the data directory and the config. The archive
	     carries the VCS private key. They are on the same disk as the data,
	     which is not a backup. Copy them somewhere else tonight.

DONE
