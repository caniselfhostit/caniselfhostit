#!/usr/bin/env bash
# PeerTube · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=video.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.joinpeertube.org/install/docker
#   https://github.com/Chocobozzz/PeerTube/tree/v8.2.4/support/docker/production
#   https://github.com/Chocobozzz/PeerTube/blob/v8.2.4/config/default.yaml
#   https://github.com/Chocobozzz/PeerTube/blob/v8.2.4/support/nginx/peertube
#
# Three secrets are generated here, on this machine: the PostgreSQL password,
# PEERTUBE_SECRET, and the password the built-in root account is created with.
# All three go into /srv/peertube/.env with mode 600 and none is ever printed.
# Upstream's own path leaves the root password to be read out of the container
# log; setting it here means you have it without printing it anywhere.
#
# DOMAIN_HOST is PEERTUBE_WEBSERVER_HOSTNAME, which is written into every embed
# code and federated video URL this instance publishes. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/peertube}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. video.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address for the administrator account"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; PeerTube plus PostgreSQL and Redis wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 40 ] || die "only ${avail_gb} GB free on /srv; this install wants 40 GB before a single video"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data and config go to uid 999, the service account the PeerTube image builds.
# Its entrypoint walks /data at every start to chown what it does not own, so
# doing it here keeps that walk short. postgres and redis stay root: both
# images chown their own data directory on first start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 999 -g 999 "$APP_DIR/data" "$APP_DIR/config"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64 for all three: Docker Compose reads this same file for
# variable interpolation and a $ in a value would be expanded. Read them later
# with
#   grep -E 'POSTGRES_PASSWORD|PEERTUBE_SECRET|PT_INITIAL_ROOT_PASSWORD' /srv/peertube/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PEERTUBE_WEBSERVER_HOSTNAME=${DOMAIN_HOST}
		PEERTUBE_ADMIN_EMAIL=${ADMIN_EMAIL}
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		PEERTUBE_SECRET=$(openssl rand -hex 32)
		PT_INITIAL_ROOT_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------
#
# This is where upstream's nginx container, certbot and reload loop went. The
# Caddyfile header maps every setting from support/nginx/peertube to its place.

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-peertube"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8124, 5432, 6379 and 1935 are not among them ----

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8124, 5432, 6379 and 1935 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# PeerTube runs its own migrations, creates the root account from
# PT_INITIAL_ROOT_PASSWORD and builds its storage tree during first boot.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/ping"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/ping" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/v1/ping answered ${code:-nothing}. Check: docker compose logs --tail 40 peertube"

curl -sS "https://${DOMAIN_HOST}/api/v1/ping" | grep -q 'pong' \
	|| die "/api/v1/ping answered 200 without pong. Check: docker compose logs --tail 40 peertube"

# Registration must be closed. This is the assert with security meaning.
curl -sS "https://${DOMAIN_HOST}/api/v1/config" | grep -q '"signup":{"allowed":false' \
	|| die "signup is not closed on this instance. Stop and check PEERTUBE_SIGNUP_ENABLED before leaving this running."

# The administrator exists, and the page Caddy serves is PeerTube's own.
curl -sS "https://${DOMAIN_HOST}/api/v1/accounts/root" | grep -q '"name":"root"' \
	|| die "the root account was not created. Check: docker compose logs --tail 60 peertube"
curl -sS "https://${DOMAIN_HOST}/login" | grep -q 'og:platform" content="PeerTube"' \
	|| die "https://${DOMAIN_HOST}/login did not serve PeerTube. Check the Caddy site block from step 4."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U peertube -d peertube | gzip > "$APP_DIR/backups/peertube-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/peertube-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env config -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/peertube-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	PeerTube is answering at https://${DOMAIN_HOST}/login

	  1. Sign in as root. Your password is in $APP_DIR/.env, mode 600:
	       grep PT_INITIAL_ROOT_PASSWORD $APP_DIR/.env
	     Put it in your password manager. It was not printed here. There is
	     no mail on this install, so the reset path is a command:
	       cd $APP_DIR && docker compose exec -u peertube peertube npm run reset-password -- -u root
	  2. Registration is closed and this run proved it. You are the only
	     account, and new ones are made from the admin screens.
	  3. Upload one short video and wait for it to play. PeerTube re-encodes
	     every upload with ffmpeg on this box, one thread by default, so ten
	     minutes of 1080p takes about ten minutes of a small VPS at 100% CPU.
	     That is this working, not failing.
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     config archive. The video files are in neither, and $APP_DIR/data is
	     the part that grows. Copy all of it somewhere else tonight.

DONE
