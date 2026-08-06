#!/usr/bin/env bash
# Grist · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=grist.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://support.getgrist.com/self-managed/
#   https://support.getgrist.com/install/forwarded-headers/
#   https://github.com/gristlabs/grist-core/blob/v1.7.17/README.md
#   https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# grist-core ships no username-and-password login of its own. This script puts
# Caddy's basic_auth in front of it and has Caddy pass the address it verified
# in X-Forwarded-User, which is the second of the two forward-auth modes
# upstream documents. Without that, a Grist on a public hostname is an open
# database.
#
# Two secrets are generated here, on this machine: the session key, in
# /srv/grist/.env, and the password on the login box, in /srv/grist/browser-login.
# Both are mode 600 and neither is ever printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/grist}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. grist.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address that will administer this Grist installation"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

caddy_major_minor="$(caddy version | head -1 | sed -n 's/^v\([0-9]*\.[0-9]*\).*/\1/p')"
case "$caddy_major_minor" in
	2.[0-7]) die "caddy $caddy_major_minor is too old; the basic_auth directive needs 2.8 or newer" ;;
esac

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Grist plus its sandbox wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# persist is left owned by root at 700. The Grist image starts as root, chowns
# everything under /persist to its own unprivileged user and then drops to it,
# so an ownership fix here would be undone on the next start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/persist"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: the login value gets typed into a browser
# dialog. Read them later with
#   sudo grep GRIST_SESSION_SECRET /srv/grist/.env
#   sudo cat /srv/grist/browser-login
#
# The login password is deliberately not in .env: .env is what compose hands to
# the container, and the credential a human types belongs nowhere near the
# application's environment.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_HOME_URL=https://${DOMAIN_HOST}
		GRIST_DEFAULT_EMAIL=${ADMIN_EMAIL}
		GRIST_SESSION_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

if [ ! -f "$APP_DIR/browser-login" ]; then
	umask 077
	openssl rand -hex 24 > "$APP_DIR/browser-login"
	chmod 600 "$APP_DIR/browser-login"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. The login box, then the Caddy site block, both on the host -----------
#
# caddy hash-password reads stdin when no --plaintext is given, which keeps the
# password out of the process list.

umask 077
caddy hash-password < "$APP_DIR/browser-login" > "$APP_DIR/grist-auth.hash"
printf 'basic_auth {\n\t%s %s\n}\n' "$ADMIN_EMAIL" "$(cat "$APP_DIR/grist-auth.hash")" > "$APP_DIR/grist-auth.conf"
umask 022
sudo install -m 640 -o root -g caddy "$APP_DIR/grist-auth.conf" /etc/caddy/grist-auth.conf
rm -f "$APP_DIR/grist-auth.hash" "$APP_DIR/grist-auth.conf"
sudo grep -q basic_auth /etc/caddy/grist-auth.conf || die "/etc/caddy/grist-auth.conf has no basic_auth block"

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-grist"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8101 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8101 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8101/status"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8101/status?db=1' || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/status answered ${code:-nothing}. Check: docker compose logs --tail 40 grist"

curl -sS 'http://127.0.0.1:8101/status?db=1' | grep -q 'is alive' \
	|| die "/status answered 200 without 'is alive'. Check: docker compose logs --tail 40 grist"
curl -sS 'http://127.0.0.1:8101/status?db=1' | grep -q 'db ok' \
	|| die "/status did not report 'db ok'. Check: docker compose logs --tail 40 grist"

# Upstream's own sandbox preflight, printed by sandbox/run.sh before the server
# starts. A kernel that will not host gvisor makes the container exit here.
docker compose logs grist | grep -q 'gvisor check ok' \
	|| die "the gvisor sandbox check did not pass. Check: docker compose logs --tail 40 grist"

# The security assert: nothing reaches Grist without a credential.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated request returned ${unauth}, not 401. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/grist-${STAMP}.tar.gz" -C "$APP_DIR" persist .env browser-login compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/grist-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Grist is answering at https://${DOMAIN_HOST}

	  1. Sign in with ${ADMIN_EMAIL} and the password in $APP_DIR/browser-login.
	     Read it with
	       sudo cat $APP_DIR/browser-login
	     and put it in your password manager. It was not printed here. That
	     login box is Caddy, not Grist: grist-core has no password login of its
	     own, which is why this install refuses every request that arrives
	     without one.
	  2. The first screen shows "Create empty document". Make one and put a
	     number in a cell before you trust anything, because that is the part
	     that uses the WebSocket the proxy has to carry.
	  3. Browsers do not offer a sign-out for this kind of login. Closing every
	     window of that browser is the sign-out.
	  4. First backup written to $APP_DIR/backups. It holds both secrets and the
	     documents, and it is on the same disk as the data, which is not a
	     backup. Copy it somewhere else tonight.

DONE
