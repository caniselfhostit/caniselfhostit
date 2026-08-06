#!/usr/bin/env bash
# Activepieces · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=flows.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.activepieces.com/docs/install/options/docker-compose
#   https://www.activepieces.com/docs/install/reference/environment-variables
#   https://www.activepieces.com/docs/install/configure-operate/production-setup
#   https://www.activepieces.com/docs/install/configure-operate/setup-ssl
#
# Three secrets are generated here, on this machine: the encryption key, the JWT
# signing secret and the PostgreSQL password. All three go into
# /srv/activepieces/.env with mode 600 and none of them is ever printed.
#
# DOMAIN_HOST is also AP_FRONTEND_URL, the hostname every webhook URL and OAuth
# redirect is built from. Choose it once; flows already running keep pointing at
# the old name if you move it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/activepieces}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. flows.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; the API and two concurrent flows want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/cache"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# The encryption key is 32 hexadecimal characters because upstream documents that
# length, which is why it is -hex 16 while the other two are -hex 32. Read them
# later with
#   sudo grep -E 'AP_ENCRYPTION_KEY|AP_JWT_SECRET|AP_POSTGRES_PASSWORD' /srv/activepieces/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		AP_FRONTEND_URL=https://${DOMAIN_HOST}
		AP_ENCRYPTION_KEY=$(openssl rand -hex 16)
		AP_JWT_SECRET=$(openssl rand -hex 32)
		AP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-activepieces"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8095, 5432 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8095, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Activepieces runs its own database migrations on the way up and then syncs the
# metadata for the piece catalogue, so the first boot takes minutes and Caddy
# answers 502 for most of them.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/health (this takes minutes on a first boot)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/v1/health answered ${code:-nothing}. Check: docker compose logs --tail 40 activepieces"

curl -sS "https://${DOMAIN_HOST}/api/v1/health" | grep -q '"status":"Healthy"' \
	|| die "/api/v1/health answered 200 without status Healthy. Check: docker compose logs --tail 40 activepieces"

# Nobody has registered yet: the flag that records the first sign-up is absent
# from the public flags document until an account exists.
if curl -sS "https://${DOMAIN_HOST}/api/v1/flags" | grep -q '"USER_CREATED":true'; then
	die "an account already exists on this instance. Stop and work out whose it is before going further."
fi

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U activepieces -d activepieces | gzip > "$APP_DIR/backups/activepieces-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/activepieces-config-${STAMP}.tar.gz" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/activepieces-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Activepieces is answering at https://${DOMAIN_HOST}/api/v1/health

	  1. Open https://${DOMAIN_HOST}/sign-up and create the first account. The
	     screen says "Create a new account". That account owns this instance, and
	     once it exists a second sign-up needs an invitation.
	     Confirm it took:
	       curl -sS https://${DOMAIN_HOST}/api/v1/flags | grep -o '"USER_CREATED":true'
	  2. Your encryption key is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep AP_ENCRYPTION_KEY $APP_DIR/.env
	     and put it in your password manager. It was not printed here. Every
	     credential you hand a piece is encrypted with it, and a database restored
	     without it comes back unreadable.
	  3. Flow code runs unsandboxed, with this container's own network reach. The
	     flows you write are the security boundary; treat a flow from someone else
	     the way you would treat a shell script from someone else.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight, and keep the pair together.

DONE
