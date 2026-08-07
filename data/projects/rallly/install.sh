#!/usr/bin/env bash
# Rallly · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=meet.example.com \
#   SUPPORT_EMAIL=you@example.com \
#   ADMIN_EMAIL=you@example.com \
#   SMTP_HOST=smtp.example.com SMTP_USER=apikey SMTP_PWD=... ./install.sh
#
# SMTP_PWD is read from the environment and never written to your terminal.
# Start that command line with a space if your shell records history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://support.rallly.co/self-hosting/installation/docker
#   https://support.rallly.co/self-hosting/configuration
#   https://support.rallly.co/self-hosting/control-panel
#   https://support.rallly.co/self-hosting/licensing
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the session key. Both go into /srv/rallly/.env with mode 600 and neither is
# ever printed.
#
# DOMAIN_HOST is also NEXT_PUBLIC_BASE_URL, the address inside every invitation
# this instance mails. Choose it once. Changing it later breaks links other
# people are already holding.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/rallly}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
SUPPORT_EMAIL="${SUPPORT_EMAIL:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_SECURE="${SMTP_SECURE:-false}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PWD="${SMTP_PWD:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. meet.example.com"
[ -n "$SUPPORT_EMAIL" ] || die "set SUPPORT_EMAIL; Rallly validates it as an email address at start-up"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address that will claim the admin role"
[ -n "$SMTP_HOST" ] || die "set SMTP_HOST; sign-in codes arrive by mail and there is no other way in"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; upstream's floor is 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex for both. Upstream documents `openssl rand -hex 32` for the session key
# and rejects anything shorter than 32 characters; the database password rides
# inside a connection string, where hex needs no escaping. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|SECRET_PASSWORD' /srv/rallly/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXT_PUBLIC_BASE_URL=https://${DOMAIN_HOST}
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		SECRET_PASSWORD=$(openssl rand -hex 32)
		REGISTRATION_ENABLED=true
		SUPPORT_EMAIL=${SUPPORT_EMAIL}
		INITIAL_ADMIN_EMAIL=${ADMIN_EMAIL}
		SMTP_HOST=${SMTP_HOST}
		SMTP_PORT=${SMTP_PORT}
		SMTP_SECURE=${SMTP_SECURE}
		SMTP_USER=${SMTP_USER}
		SMTP_PWD=${SMTP_PWD}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-rallly"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8153 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8153 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The container applies its own Prisma migrations before the server listens, so
# a first boot takes minutes rather than seconds.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/status"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/status" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/status answered ${code:-nothing}. Check: docker compose logs --tail 60 rallly"

status="$(curl -sS "https://${DOMAIN_HOST}/api/status" || true)"
case "$status" in
	*'"status":"ok"'*) : ;;
	*) die "/api/status answered 200 without status ok. Check: docker compose logs --tail 60 rallly" ;;
esac
case "$status" in
	*'"database":"connected"'*) : ;;
	*) die "the app is up but reports the database disconnected. Check: docker compose logs --tail 20 postgres" ;;
esac

# The login page has to render the sign-up wording while registration is open.
login_open="$(curl -sS "https://${DOMAIN_HOST}/login" | grep -c '>Log in to your account or create a new one</p>' || true)"
[ "$login_open" = "1" ] || die "https://${DOMAIN_HOST}/login did not render the expected first screen"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U rallly -d rallly | gzip > "$APP_DIR/backups/rallly-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/rallly-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/rallly-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Rallly is answering at https://${DOMAIN_HOST}/login

	  1. Sign in at https://${DOMAIN_HOST}/login with ${ADMIN_EMAIL}. Rallly
	     mails you a six-digit code; that code arriving is the only proof your
	     relay works. If it does not, add SMTP_DEBUG=true to $APP_DIR/.env,
	     recreate the container, and read the log.
	  2. Then open https://${DOMAIN_HOST}/control-panel and press the button
	     that makes you an admin.
	  3. Registration is still open, which on a public hostname is an account
	     for anyone who can receive mail. Once you are signed in, close it:
	       cd $APP_DIR
	       sed -i 's/^REGISTRATION_ENABLED=true\$/REGISTRATION_ENABLED=false/' .env
	       docker compose up -d --force-recreate rallly
	     Then confirm the login page says "Login to your account to continue".
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
