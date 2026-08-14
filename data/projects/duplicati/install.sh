#!/usr/bin/env bash
# Duplicati · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=backup.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/README.md
#   https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/ReleaseBuilder/Resources/Docker/Dockerfile
#   https://github.com/duplicati/duplicati/blob/v2.3.0.4_stable_2026-07-09/Duplicati/WebserverCore/Services/HostnameValidator.cs
#
# Two secrets are generated here, on this machine, into /srv/duplicati/.env at
# mode 600, and neither is printed. The first one is the web password. A
# Duplicati started without one generates a random password and writes a
# one-time sign-in link into the container log, which is a credential sitting
# in `docker compose logs` on a public hostname. The second encrypts the
# credential fields inside the settings database, where the storage
# destination's access keys will live.
#
# The backup passphrase you type into the UI later is a different thing again,
# and nothing here can recover it. Keep it where you keep this login.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/duplicati}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
PORT="8188"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. backup.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Duplicati wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB for the image, the upload temp files and the job database"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# backups belongs to the login user; data and restore are written by the
# container, which runs as root because the files it reads under /srv were
# written by other services as other users.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/data" "$APP_DIR/restore"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64, because one of them is typed into a login form. Read
# the web password later with
#   sudo grep DUPLICATI__WEBSERVICE_PASSWORD /srv/duplicati/.env
# The third line holds nothing private. It is the hostname the API answers for,
# and Duplicati's allowed-hostname list ships holding localhost, 127.0.0.1 and
# bare IP addresses, so without it every request through Caddy comes back 403.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DUPLICATI__WEBSERVICE_PASSWORD=$(openssl rand -hex 24)
		SETTINGS_ENCRYPTION_KEY=$(openssl rand -hex 32)
		DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES=${DOMAIN_HOST}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

env_host="$(sudo grep DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES "$APP_DIR/.env" | cut -d= -f2- || true)"
echo "==> allowed hostname in .env: ${env_host}"
[ "$env_host" = "$DOMAIN_HOST" ] || die "the .env allowed hostname is '${env_host}', not '${DOMAIN_HOST}'. An older .env is in place; move it aside and run this again."

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-duplicati"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8188 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; ${PORT} stays closed on loopback"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/health answered ${code:-nothing}. Check: docker compose logs --tail 40 duplicati"

health="$(curl -sS "https://${DOMAIN_HOST}/health" || true)"
echo "==> /health said: ${health}"
[ "$health" = "Healthy" ] || die "/health returned '${health}', not 'Healthy'. Caddy may be reaching something other than Duplicati."

# The API must refuse a call with no token. A 200 here would mean the request
# never reached Duplicati, because this build has no way to turn auth off.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/backups" || true)"
echo "==> unauthenticated /api/v1/backups: ${unauth}"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and find out what is answering."

# And it must accept the generated password. The value goes to curl on standard
# input, so it never appears in a command line. A 403 here means the hostname in
# .env and the Caddy site block disagree.
authed="$(printf '{"Password":"%s","RememberMe":false}' "$(sudo grep DUPLICATI__WEBSERVICE_PASSWORD "$APP_DIR/.env" | cut -d= -f2-)" \
	| curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/v1/auth/login" \
	-H 'Content-Type: application/json' --data-binary @- || true)"
echo "==> login with the generated credential returned: ${authed}"
[ "$authed" = "200" ] || die "the generated login returned ${authed}, not 200. A 403 means the allowed hostname and the Caddy block disagree; a 401 means the container started before .env existed."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/duplicati-config-${STAMP}.tar.gz" -C "$APP_DIR" data compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/duplicati-config-${STAMP}.tar.gz" ] || die "the configuration archive is empty"

cat <<-DONE

	Duplicati is answering at https://${DOMAIN_HOST}/ and refusing unauthenticated API calls.

	  1. There is no username. The password is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep DUPLICATI__WEBSERVICE_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Nothing is backed up yet. Open https://${DOMAIN_HOST}/, sign in, then Add backup:
	     set a passphrase, pick a destination, and add /source as the source folder with
	     /source/duplicati excluded. This server's /srv is /source inside the container,
	     and /source/duplicati is this app's own state.
	  3. That passphrase encrypts every file before it leaves this box. Nothing here can
	     recover it, so losing it makes the destination unreadable to you too.
	  4. Restore one file from your first job into /restore and look at it with
	       sudo ls -lR $APP_DIR/restore
	     A backup nobody has restored is a hope.
	  5. First backup of this install written to $APP_DIR/backups. It holds .env, so it
	     holds the key protecting the rest of it, and it is on the same disk as the data,
	     which is not a backup. Copy it somewhere else tonight.

DONE
