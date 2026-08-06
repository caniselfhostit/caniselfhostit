#!/usr/bin/env bash
# LinkStack · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=links.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.linkstack.org/docker/setup/
#   https://docs.linkstack.org/docker/reverse-proxies/
#   https://github.com/LinkStackOrg/linkstack-docker/blob/main/Dockerfile
#   https://github.com/LinkStackOrg/LinkStack/blob/v4.8.6/.env
#   https://caddyserver.com/docs/automatic-https
#
# Nothing is generated here. LinkStack's only credential is the administrator
# account, and you create it in a browser at step 6. The .env this script writes
# is configuration: the hostname Apache answers to.
#
# DOMAIN_HOST is the address on every profile link and QR code you hand out.
# Choose it once; moving it later means reprinting whatever the code is on.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/linkstack}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. links.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; Apache plus PHP wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Two files under /srv. The application, its themes, its uploads and its SQLite
# database live in a Docker volume: the image ships the application at /htdocs,
# and Docker fills an empty named volume from the image but never a bind mount.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		HTTP_SERVER_NAME=${DOMAIN_HOST}
		HTTPS_SERVER_NAME=${DOMAIN_HOST}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-linkstack"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8121 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8121 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it and prove it is serving --------------------------------------
#
# FORCE_HTTPS lives in the application's own .env inside the volume, so it can
# only be set once the container has filled that volume from the image. It makes
# the application write https:// into the pages Caddy serves; without it the
# setup form posts to http:// and a browser blocks the request.

docker compose pull
docker compose up -d

echo "==> waiting for the container's own health check to go green"
for _ in $(seq 1 48); do
	state="$(docker inspect --format '{{.State.Health.Status}}' linkstack 2>/dev/null || echo starting)"
	[ "$state" = "healthy" ] && break
	sleep 5
done
[ "${state:-}" = "healthy" ] || die "container health is ${state:-unknown}. Check: docker compose logs --tail 40 linkstack"

docker compose exec -T linkstack sed -i 's/^FORCE_HTTPS=false$/FORCE_HTTPS=true/' /htdocs/.env
docker compose exec -T linkstack grep -q '^FORCE_HTTPS=true$' /htdocs/.env \
	|| die "FORCE_HTTPS did not take in /htdocs/.env. Check: docker compose exec -T linkstack cat /htdocs/.env"

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: sudo journalctl -u caddy -n 30"

curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Setup LinkStack' \
	|| die "the page answered 200 without the setup heading. Check: docker compose logs --tail 40 linkstack"

# --- 6. Create the administrator account, in a browser ------------------------
#
# The wizard is the only way in. While the INSTALLING marker is present its
# routes answer without a login, including one that seeds a default
# administrator, so this window is short on purpose.

cat <<-SETUP

	Open https://${DOMAIN_HOST} now and work through the five setup screens.
	Three answers matter:

	  - choose SQLite when it asks for a database type
	  - use a password from your password manager on the admin screen
	  - set "Enable registration" to No on the last screen

	Do it now rather than later: until that wizard is finished, anyone who
	loads the page can finish it instead of you.

SETUP
printf 'Press Return once the wizard has finished and you are looking at the dashboard. '
read -r _

# --- 7. Prove the install closed behind you -----------------------------------

reg="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/register" || true)"
[ "$reg" = "404" ] || die "https://${DOMAIN_HOST}/register returned ${reg}, not 404. Registration is still open; turn it off in the admin panel."

docker compose exec -T linkstack sh -c 'test ! -f /htdocs/INSTALLING' \
	|| die "the setup marker is still present, so the installer routes are still live. Finish the wizard's last screen."

curl -sSL "https://${DOMAIN_HOST}/login" | grep -q 'Sign In' \
	|| die "the sign-in page did not render. Check: docker compose logs --tail 40 linkstack"

docker compose exec -T linkstack sh -c "sed -i 's/^APP_DEBUG=true\$/APP_DEBUG=false/; s/^APP_ENV=local\$/APP_ENV=production/' /htdocs/.env"
docker compose exec -T linkstack grep -q '^APP_DEBUG=false$' /htdocs/.env \
	|| die "APP_DEBUG is still true, so PHP errors would show a stack trace to visitors"

# --- 8. The first backup, before day one ends ---------------------------------
#
# Two artifacts: what you made, and the files that rebuild the service around it.
# The data archive leaves out the application code, which comes back from the
# pinned image. Its .env carries APP_KEY, which is the one value in here that
# cannot be replaced.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T linkstack tar -czf - -C /htdocs .env database assets/img themes > "$APP_DIR/backups/linkstack-data-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/linkstack-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/linkstack-data-${STAMP}.tar.gz" ] || die "the data archive is empty"
[ -s "$APP_DIR/backups/linkstack-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	LinkStack is answering at https://${DOMAIN_HOST}/

	  1. Registration is off and the setup routes are gone. Both were checked,
	     not assumed: /register returns 404 and the INSTALLING marker is gone.
	  2. Your page lives at https://${DOMAIN_HOST}/@ plus the handle you chose,
	     and the admin panel is at https://${DOMAIN_HOST}/dashboard
	  3. Updating is two separate jobs. The application updates from inside,
	     through the admin panel's updater, which rewrites the volume. The
	     runtime updates by editing the image digest in $APP_DIR/compose.yml.
	     Back up before either.
	  4. First backup written to $APP_DIR/backups: a data archive and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
