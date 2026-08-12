#!/usr/bin/env bash
# ntfy · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=ntfy.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.ntfy.sh/install/#docker
#   https://docs.ntfy.sh/config/
#   https://docs.ntfy.sh/config/#access-control
#
# One secret is generated here: the password for the admin user. It goes into
# /srv/ntfy/.env with mode 600 and is never printed. The admin account is then
# created with NTFY_PASSWORD=... ntfy user add (upstream's non-interactive path).
# Auth default is deny-all, so anonymous publish is refused until that user exists.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/ntfy}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_USER="${ADMIN_USER:-admin}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. ntfy.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 256 ] || die "only ${avail_mb} MB of RAM available; this install wants 256 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 2 ] || die "only ${avail_gb} GB free on /srv; this install wants 2 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/cache" "$APP_DIR/auth"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the admin password, on the server ---------------------------
#
# Username is admin (override with ADMIN_USER). Read the password later with
#   sudo grep NTFY_PASSWORD /srv/ntfy/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NTFY_BASE_URL=https://${DOMAIN_HOST}
		NTFY_USERNAME=${ADMIN_USER}
		NTFY_PASSWORD=$(openssl rand -base64 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-ntfy"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8200 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8200 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it, create the admin user, close the door ----------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/v1/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/v1/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/v1/health answered ${code:-nothing}. Check: docker compose logs --tail 40 ntfy"

# Create the admin account non-interactively (upstream supports NTFY_PASSWORD=).
# Skip if the user already exists (re-run of this script).
NTFY_PASS="$(grep -E '^NTFY_PASSWORD=' "$APP_DIR/.env" | cut -d= -f2-)"
NTFY_USER="$(grep -E '^NTFY_USERNAME=' "$APP_DIR/.env" | cut -d= -f2-)"
[ -n "$NTFY_PASS" ] || die "NTFY_PASSWORD missing from $APP_DIR/.env"
if ! docker compose exec -T ntfy ntfy user list 2>/dev/null | grep -q "user ${NTFY_USER} "; then
	docker compose exec -T -e "NTFY_PASSWORD=${NTFY_PASS}" ntfy ntfy user add --role=admin "${NTFY_USER}" \
		|| die "failed to create admin user ${NTFY_USER}"
fi

# Anonymous publish must be refused.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' -d 'probe' "https://${DOMAIN_HOST}/caniselfhostit-probe" || true)"
[ "$unauth" = "403" ] || die "anonymous publish returned ${unauth}, not 403. Auth is not closed."

# Authenticated publish must succeed.
auth="$(curl -sS -o /dev/null -w '%{http_code}' -u "${NTFY_USER}:${NTFY_PASS}" -d 'install ok' "https://${DOMAIN_HOST}/caniselfhostit-probe" || true)"
[ "$auth" = "200" ] || die "authenticated publish returned ${auth}, not 200. Check: docker compose logs --tail 40 ntfy"

# --- 7. The first backup, before day one ends --------------------------------
#
# Stopped on purpose: the SQLite cache and auth files should not be copied
# mid-write. Downtime is a few seconds.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/ntfy-${STAMP}.tar.gz" -C "$APP_DIR" cache auth compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/ntfy-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	ntfy is answering at https://${DOMAIN_HOST}/

	  1. Your username is ${NTFY_USER}. Read the password once with
	       sudo grep NTFY_PASSWORD $APP_DIR/.env
	     put it in your password manager, and do not paste it anywhere else.
	     It was not printed here. There is no browser setup wizard: users are
	     created with ntfy user add on the server.
	  2. Anonymous publish is denied (deny-all). Publish with
	       curl -u ${NTFY_USER}:\$PASSWORD -d "hello" https://${DOMAIN_HOST}/your-topic
	  3. On a phone, open the ntfy app, add this server as a base URL, log in
	     with the same account, and subscribe to a topic. iOS instant delivery
	     needs NTFY_UPSTREAM_BASE_URL=https://ntfy.sh (routes through ntfy.sh
	     APNS); without it, iOS delivery is delayed. Android uses the app's own
	     connection or a UnifiedPush distributor and needs no bridge.
	  4. First backup written to $APP_DIR/backups (cache, auth, .env, compose,
	     live Caddyfile). It is on the same disk as the data, which is not a
	     backup. Copy it somewhere else tonight.

DONE
