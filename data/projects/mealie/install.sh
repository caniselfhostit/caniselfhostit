#!/usr/bin/env bash
# Mealie · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=recipes.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.mealie.io/documentation/getting-started/installation/installation-checklist/
#   https://docs.mealie.io/documentation/getting-started/installation/sqlite/
#   https://docs.mealie.io/documentation/getting-started/installation/backend-config/
#   https://docs.mealie.io/documentation/getting-started/usage/backups-and-restoring/
#
# One secret is generated here, on this machine: the password that replaces the
# one the image seeds its admin account with. It goes into /srv/mealie/.env with
# mode 600 and is never printed.
#
# The image seeds an account whose email and password upstream publishes. This
# script does not finish until that password has been replaced and the published
# one has been proved to fail.
#
# DOMAIN_HOST becomes BASE_URL, the address Mealie writes into the invitation
# links it sends. Changing it later invalidates invitations already out.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/mealie}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
SHIPPED_EMAIL="changeme@example.com"
SHIPPED="MyPassword"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. recipes.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || [ "$arch" = "arm64" ] || die "architecture ${arch} is not built by upstream; Mealie needs amd64 or arm64"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data/ is left alone on purpose: the image runs as uid 911 and chowns /app on
# the way up, so this directory belongs to 911 after the first start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: it travels inside a JSON body. Read it later with
#   grep ADMIN_PASSWORD /srv/mealie/.env
# Mealie writes its own token signing keys into data/ on first start, so there
# is nothing else here to create.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASE_URL=https://${DOMAIN_HOST}
		TZ=UTC
		ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-mealie"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8117 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8117 stays on loopback"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/app/about"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/app/about" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/app/about answered ${code:-nothing}. Check: docker compose logs --tail 40 mealie"

curl -sS "https://${DOMAIN_HOST}/api/app/about" | grep -q '"version":"v3.22.0"' \
	|| die "the running container is not v3.22.0. Check: docker compose logs --tail 40 mealie"
curl -sS "https://${DOMAIN_HOST}/api/app/about" | grep -q '"allowSignup":false' \
	|| die "open registration is on. Stop and check ALLOW_SIGNUP in compose.yml."

# --- 7. Replace the password the image seeds ---------------------------------
#
# Upstream publishes both halves of this credential in its installation
# checklist, so it is a known login on a public hostname until the next twenty
# lines have run. The new value is piped in from .env rather than written on a
# command line, so it never reaches the process list.

TOKEN="$(curl -sS -X POST "https://${DOMAIN_HOST}/api/auth/token" \
	--data-urlencode "username=${SHIPPED_EMAIL}" \
	--data-urlencode "password=${SHIPPED}" \
	| sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
[ -n "$TOKEN" ] || die "could not sign in as the seeded account. Stop: the shipped password may already have been changed, or the API is not ready."

changed="$(printf '{"currentPassword":"%s","newPassword":"%s"}' "$SHIPPED" "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' "$APP_DIR/.env")" \
	| curl -sS -o /dev/null -w '%{http_code}' -X PUT "https://${DOMAIN_HOST}/api/users/password" \
		-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' --data-binary @-)"
[ "$changed" = "200" ] || die "the password change returned ${changed}, not 200. Stop and investigate."

refused="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/auth/token" \
	--data-urlencode "username=${SHIPPED_EMAIL}" \
	--data-urlencode "password=${SHIPPED}" || true)"
[ "$refused" = "401" ] || die "the published password still returns ${refused}, not 401. This install is not safe to leave running."
unset TOKEN

# --- 8. The first backup, before day one ends --------------------------------
#
# Upstream's advice for SQLite is to stop the container and copy the data
# directory whole. The config archive picks up the live Caddy site block, not
# the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/mealie-data-${STAMP}.tar.gz" -C "$APP_DIR" data
docker compose start
sudo tar -czf "$APP_DIR/backups/mealie-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/mealie-data-${STAMP}.tar.gz" ] || die "the data archive is empty"

cat <<-DONE

	Mealie is answering at https://${DOMAIN_HOST}

	  1. Sign in as ${SHIPPED_EMAIL}. Your password is in $APP_DIR/.env,
	     mode 600. Read it with
	       grep ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here. The
	     password the image ships with was replaced and proved to fail.
	  2. Change that email address to your own under user settings. The
	     sign-in page keeps showing a first-login banner with the published
	     credentials until you do, and the banner keys off the address.
	  3. Recipes import from a URL on most sites. Sites behind a bot check, or
	     that build the page with JavaScript, come back empty; paste those in
	     by hand. Existing Paprika, Tandoor and Nextcloud Cookbook exports
	     import at /group/migrations.
	  4. First backup written to $APP_DIR/backups: the data directory and a
	     config archive. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight.

DONE
