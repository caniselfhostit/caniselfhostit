#!/usr/bin/env bash
# KitchenOwl · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=kitchen.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.kitchenowl.org/v0.7.10/self-hosting/
#   https://docs.kitchenowl.org/v0.7.10/self-hosting/advanced/
#   https://docs.kitchenowl.org/v0.7.10/self-hosting/reverse-proxy/
#   https://github.com/TomBursch/kitchenowl/blob/v0.7.10/Dockerfile
#
# One secret is generated here, on this machine: the JWT signing key. Upstream's
# own sample sets it to a fixed placeholder printed in its documentation, so an
# install that keeps the default can have its session tokens minted by a
# stranger. It goes into /srv/kitchenowl/.env with mode 600 and is never printed.
#
# This script cannot open a browser, so it cannot claim the owner account for
# you. It finishes with that account still unclaimed and says so loudly. Claim
# it the minute this returns: the first person to complete the onboarding form
# on your hostname becomes the admin, and that is the whole risk in this install.
#
# DOMAIN_HOST becomes FRONT_URL, the address every phone in the household types
# into the KitchenOwl app. Changing it later means visiting every phone.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/kitchenowl}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
HEALTH_PATH="/api/health/8M4F88S8ooi4sMbLBfkkV7ctWwgibW6V"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. kitchen.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || [ "$arch" = "arm64" ] || die "architecture ${arch} is not built by upstream; KitchenOwl needs amd64 or arm64"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data/ is left alone on purpose: the container process runs as root and writes
# the SQLite file and the upload directory there itself.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: it travels in a container environment variable. Read
# it later, if you ever need to, with
#   sudo grep JWT_SECRET_KEY /srv/kitchenowl/.env
# You will not type it anywhere. Rotating it signs every phone and browser out.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		FRONT_URL=https://${DOMAIN_HOST}
		JWT_SECRET_KEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-kitchenowl"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8167 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8167 stays on loopback"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The container migrates its database and imports a default item list on the way
# up, so the first start is slower than the ones after it.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}${HEALTH_PATH}"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}${HEALTH_PATH}" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the health route answered ${code:-nothing}. Check: docker compose logs --tail 40 kitchenowl"

health="$(curl -sS "https://${DOMAIN_HOST}${HEALTH_PATH}")"
printf '%s' "$health" | grep -qE '"msg":[[:space:]]*"OK"' \
	|| die "the health route answered 200 without msg OK. Check: docker compose logs --tail 40 kitchenowl"

# The server only prints open_registration when public signups are on, so its
# absence here is the report that they are off.
if printf '%s' "$health" | grep -q 'open_registration'; then
	die "public registration is on. Stop and check OPEN_REGISTRATION in compose.yml."
fi

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>KitchenOwl</title>' \
	|| die "the root page did not return the KitchenOwl title. Check that Caddy is reaching 8167."

# With registration off the server publishes no signup route at all, so a 404
# here is the correct answer and a 200 would mean signups are open.
signup="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/auth/signup" || true)"
[ "$signup" = "404" ] || die "POST /api/auth/signup returned ${signup}, not 404. This install is not safe to leave running."

onboarding="$(curl -sS "https://${DOMAIN_HOST}/api/onboarding")"
if printf '%s' "$onboarding" | grep -qE '"onboarding":[[:space:]]*true'; then
	echo "==> the owner account is UNCLAIMED. Read item 1 below the moment this finishes."
else
	echo "==> onboarding already reports closed, so an account exists on this server"
fi

# --- 7. The first backup, before day one ends --------------------------------
#
# The container stops for the data archive: a SQLite file copied while it is
# being written is not a backup. The config archive picks up the live Caddy site
# block, not the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/kitchenowl-data-${STAMP}.tar.gz" -C "$APP_DIR" data
docker compose start
sudo tar -czf "$APP_DIR/backups/kitchenowl-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/kitchenowl-data-${STAMP}.tar.gz" ] || die "the data archive is empty"

cat <<-DONE

	KitchenOwl is answering at https://${DOMAIN_HOST}

	  1. DO THIS NOW. Open https://${DOMAIN_HOST}, press Start, and create your
	     account. The first account made through that form becomes the owner,
	     with admin rights, and until you make it that offer is open to anyone
	     who reaches your hostname. This script cannot open a browser, so it is
	     the one step it could not do for you. Confirm it took with
	       curl -sS https://${DOMAIN_HOST}/api/onboarding
	     whose onboarding field reads false once the account exists.
	  2. Everyone else in the household joins by invitation from inside the
	     app. Public signups are off and the server publishes no signup route.
	  3. The phone apps are the reason to run this: install KitchenOwl from
	     your app store, choose the option to use your own server, and give it
	     https://${DOMAIN_HOST}. That address is FRONT_URL in $APP_DIR/.env,
	     mode 600, and the signing key sits in the same file. Neither was
	     printed here.
	  4. First backup written to $APP_DIR/backups: the data directory and a
	     config archive. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight.

DONE
