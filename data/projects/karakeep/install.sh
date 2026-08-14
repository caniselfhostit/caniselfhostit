#!/usr/bin/env bash
# Karakeep · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=keep.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.karakeep.app/installation/docker
#   https://docs.karakeep.app/configuration/environment-variables
#   https://docs.karakeep.app/installation/minimal-install
#   https://docs.karakeep.app/administration/security-considerations
#   https://docs.karakeep.app/administration/troubleshooting
#
# Two secrets are generated here, on this machine: NEXTAUTH_SECRET, which signs
# the session tokens, and MEILI_MASTER_KEY, which is the only credential the
# search engine accepts. Both go into /srv/karakeep/.env with mode 600 and
# neither is ever printed.
#
# This script cannot create your account, because only a browser can. It stops
# with registration still open and tells you to go and claim the instance.
# Karakeep gives the admin role to whoever registers while the users table is
# empty, so until you do that, this hostname is offering the administrator
# account to anyone who knows it. Claiming it and running the two closing
# commands in the summary below is the whole security story of this install.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/karakeep}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. keep.example.com"
case "$DOMAIN_HOST" in
	*/*) die "DOMAIN_HOST is a hostname, not a URL: no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; the app, a headless Chrome and Meilisearch want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; archived pages and screenshots want 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')" || resolved=""
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Two owners, on purpose. The Karakeep and Meilisearch images both run as root
# inside their containers and write to their mounts, so those two directories
# stay with root. Everything you touch by hand stays yours. Keep data/ on local
# disk: db.db is a SQLite file and a network mount corrupts one quietly.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/data" "$APP_DIR/meili"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Upstream documents the generator below for both: base64 for NEXTAUTH_SECRET
# and alphanumerics only for MEILI_MASTER_KEY. Read them later with
#   sudo grep -E 'NEXTAUTH_SECRET|MEILI_MASTER_KEY' /srv/karakeep/.env
# Changing NEXTAUTH_SECRET signs everyone out. Changing MEILI_MASTER_KEY leaves
# an index the app can no longer open, and you reindex from the admin screens.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXTAUTH_URL=https://${DOMAIN_HOST}
		DISABLE_SIGNUPS=false
		NEXTAUTH_SECRET=$(openssl rand -base64 36)
		MEILI_MASTER_KEY=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9')
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-karakeep"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8182, 7700 or 9222 is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8182, 7700 and 9222 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The web image runs the database migration, the Next.js app and the background
# workers together under s6, so the first boot writes the schema before it
# answers anything. The first pull is around a gigabyte across three images.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 36); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health")" || code="no-answer"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 web"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"status":"ok"' \
	|| die "/api/health answered 200 without status ok. Check: docker compose logs --tail 40 web"

# The sign-in page is the first screen. Its absence means Caddy is reaching
# something other than Karakeep.
curl -sSL "https://${DOMAIN_HOST}/signin" | grep -q 'Welcome Back' \
	|| die "https://${DOMAIN_HOST}/signin does not carry the sign-in heading"

# The REST API must refuse a call carrying no bearer token.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/bookmarks")" || unauth="no-answer"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# Meilisearch has no host port, and it still refuses an unauthenticated call
# from inside the compose network. This runs the check from the web container.
meili="$(docker compose exec -T web curl -sS -o /dev/null -w '%{http_code}' http://meilisearch:7700/indexes)" || meili="no-answer"
[ "$meili" = "401" ] || die "meilisearch answered ${meili} to an unauthenticated call, not 401. Check MEILI_MASTER_KEY in .env."

# Registration is open, and the summary below is about closing it. Confirming
# the form is there is the last check; claiming it is the first thing you do.
curl -sSL "https://${DOMAIN_HOST}/signup" | grep -q 'Create Your Account' \
	|| die "https://${DOMAIN_HOST}/signup is not offering the registration form; a user may already exist"

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped on purpose: a SQLite file copied mid-write is not a backup. Downtime
# is a few seconds. meili/ is not in the archive, because the search index is
# rebuilt from the database by Reindex All Bookmarks in the admin screens.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/karakeep-${STAMP}.tar.gz" -C "$APP_DIR" data .env compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/karakeep-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Karakeep is answering at https://${DOMAIN_HOST}

	  1. Do this now, before anything else, and do not walk away in the middle.
	     Open
	       https://${DOMAIN_HOST}/signup
	     and create your account. Whoever registers first becomes the
	     administrator of this instance. Then come straight back and shut the
	     door:

	       cd $APP_DIR
	       sed -i 's/^DISABLE_SIGNUPS=false\$/DISABLE_SIGNUPS=true/' .env
	       docker compose up -d --force-recreate --no-deps web
	       sleep 20
	       docker compose exec -T web printenv DISABLE_SIGNUPS
	       curl -sSL https://${DOMAIN_HOST}/signup | grep -c 'Create Your Account'

	     The last two lines must print \`true\` and \`0\`. A restart is not enough:
	     docker compose only re-reads .env when the container is recreated,
	     which is what --force-recreate is for.
	  2. The crawler drives a real browser from inside your network, and
	     upstream names limiting access to trusted users as the first
	     mitigation. That is the same thing as keeping signups shut. Add people
	     by opening the door for a minute, not by leaving it open.
	  3. AI tagging is off. It needs your own OpenAI key or your own Ollama
	     endpoint, and the bill is yours. Add OPENAI_API_KEY=... to
	     $APP_DIR/.env and recreate the web container to turn it on.
	     Everything else works without it.
	  4. Your two secrets are in $APP_DIR/.env, mode 600. Read them with
	       sudo grep -E 'NEXTAUTH_SECRET|MEILI_MASTER_KEY' $APP_DIR/.env
	     and put them in your password manager. Neither was printed here.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
