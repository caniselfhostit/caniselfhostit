#!/usr/bin/env bash
# Docmost · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=wiki.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docmost.com/docs/installation
#   https://docmost.com/docs/self-hosting/environment-variables
#   https://docmost.com/docs/self-hosting/reverse-proxy
#   https://docmost.com/docs/self-hosting/reverse-proxy/caddy
#
# Two secrets are generated here, on this machine: the application secret and
# the PostgreSQL password. Both go into /srv/docmost/.env with mode 600 and
# neither is ever printed.
#
# DOMAIN_HOST is also APP_URL. Docmost builds every invitation link and every
# shared page link out of APP_URL, so choose the hostname you intend to keep.
#
# The last step of this script leaves the workspace uncreated on purpose: only
# a human at a browser can fill in the setup form, and the closing summary says
# how to confirm that registration closed behind them.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/docmost}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. wiki.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Docmost plus PostgreSQL plus Redis wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Three owners, three reasons. Attachments live in storage, which the Docmost
# image writes as its base image's node user, uid 1000. PostgreSQL and Redis
# each chown their own data directory at start-up, so those two stay root-owned
# and untouched.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 -o 1000 -g 1000 "$APP_DIR/storage"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: DB_PASSWORD is interpolated into a
# PostgreSQL connection string, and a / or a + inside a URL is an argument
# nobody needs to have. Read them later with
#   sudo grep -E 'APP_SECRET|DB_PASSWORD' /srv/docmost/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		APP_SECRET=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-docmost"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8092, 5432 or 6379 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8092, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Docmost runs its own database migrations on the way up, so the first start is
# slower than every one after it.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 docmost"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"status":"ok"' \
	|| die "/api/health answered 200 without status ok. Check: docker compose logs --tail 40 docmost"

# No workspace exists yet, and upstream answers 404 for that. Anything else here
# means the request is not reaching Docmost.
setup_state="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/workspace/public" || true)"
[ "$setup_state" = "404" ] || die "/api/workspace/public returned ${setup_state}, not 404. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U docmost -d docmost | gzip > "$APP_DIR/backups/docmost-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/docmost-files-${STAMP}.tar.gz" -C "$APP_DIR" storage compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/docmost-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Docmost is answering at https://${DOMAIN_HOST}/api/health

	  1. Open https://${DOMAIN_HOST}/setup/register in a browser. The first
	     screen reads "Create workspace" and asks for a workspace name, your
	     name, your email and a password of at least 8 characters. That first
	     account becomes the workspace owner.
	  2. Then confirm nobody else can claim one, from this server:
	       curl -sS -w '\n%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' \\
	         https://${DOMAIN_HOST}/api/auth/setup
	     It must answer 403 with "Workspace setup already completed." Until
	     step 1 is done, a stranger who finds this hostname can create the
	     owner account instead of you, so do not leave it overnight.
	  3. Your two secrets are in $APP_DIR/.env, mode 600, and were not printed
	     here. Read them yourself with
	       sudo grep -E 'APP_SECRET|DB_PASSWORD' $APP_DIR/.env
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding the attachments and the config. They are on the same
	     disk as the data, which is not a backup. Copy them somewhere else
	     tonight.

DONE
