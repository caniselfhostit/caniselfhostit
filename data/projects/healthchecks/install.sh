#!/usr/bin/env bash
# Healthchecks · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=checks.example.com ADMIN_EMAIL=you@example.com \
#     RELAY_HOST=smtp.example.net RELAY_PORT=587 RELAY_USER=you@example.com ./install.sh
#
# It will prompt once, silently, for the relay credential. That value is never
# echoed and never reaches your shell history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/healthchecks/healthchecks/blob/master/docker/README.md
#   https://healthchecks.io/docs/self_hosted_configuration/
#   https://caddyserver.com/docs/automatic-https
#
# One secret is generated here, on this machine: the Django SECRET_KEY. It is
# written to /srv/healthchecks/.env with mode 600 and never printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/healthchecks}"
IMAGE="healthchecks/healthchecks:v4.3@sha256:cd7bcd94350818b3944f82eb5995f48bdeab8c8627977578a569ffa73f56f56f"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
RELAY_HOST="${RELAY_HOST:-}"
RELAY_PORT="${RELAY_PORT:-587}"
RELAY_USER="${RELAY_USER:-$ADMIN_EMAIL}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. checks.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address your first account will use"
[ -n "$RELAY_HOST" ]  || die "set RELAY_HOST to an SMTP relay you already have. Alert mail is the whole product."
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image creates /data and hands it to a system account called hc. Ask the
# image which uid that is rather than assuming one.

docker pull "$IMAGE"
HCUID="$(docker run --rm "$IMAGE" id -u hc)"
[ -n "$HCUID" ] || die "could not read the hc uid out of the image"
echo "==> the container writes as uid ${HCUID}"

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o "$HCUID" -g "$HCUID" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. One generated secret, plus the relay credential you already own ------
#
# SECRET_KEY has never existed anywhere else. The relay credential is typed in
# below, silently, and appended without ever being echoed.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SECRET_KEY=$(openssl rand -base64 48)
		SITE_ROOT=https://${DOMAIN_HOST}
		SITE_NAME=Checks
		ALLOWED_HOSTS=${DOMAIN_HOST}
		DB=sqlite
		DB_NAME=/data/hc.sqlite
		REGISTRATION_OPEN=True
		DEFAULT_FROM_EMAIL=${ADMIN_EMAIL}
		EMAIL_HOST=${RELAY_HOST}
		EMAIL_PORT=${RELAY_PORT}
		EMAIL_HOST_USER=${RELAY_USER}
		EMAIL_USE_TLS=True
	ENVFILE
	printf 'EMAIL_HOST_PASSWORD=' >> "$APP_DIR/.env"
	printf 'Relay credential for %s (input is hidden): ' "$RELAY_USER" > /dev/tty
	read -rs relay_value < /dev/tty
	printf '\n' > /dev/tty
	printf '%s\n' "$relay_value" >> "$APP_DIR/.env"
	unset relay_value
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

sudo awk -F= '/^EMAIL_HOST_PASSWORD/ {print "relay credential recorded, length " length($2)}' "$APP_DIR/.env"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-healthchecks"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8088 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8088 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it and prove it works ------------------------------------------

docker compose up -d
sleep 20

echo "==> waiting for https://${DOMAIN_HOST}/api/v3/status/ (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v3/status/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "the status endpoint answered ${code:-nothing}. Check: docker compose logs --tail 40 healthchecks"

# --- 7. Create your account, then close registration -------------------------

cat <<-SIGNUP

	Open https://${DOMAIN_HOST}/accounts/signup/ now, sign up as ${ADMIN_EMAIL},
	and click the link Healthchecks emails you. That link is how you get in the
	first time, so if it does not arrive, read step 10 of the prompt before you
	change anything: outbound mail is blocked by default on most new VPS
	accounts, and that is not a bug in this install.

SIGNUP
printf 'Press Return once you are signed in. '
read -r _

sed -i 's/^REGISTRATION_OPEN=True$/REGISTRATION_OPEN=False/' "$APP_DIR/.env"
docker compose up -d --force-recreate
sleep 20
signup_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/accounts/signup/" || true)"
echo "==> the sign-up page now answers ${signup_code}"
[ "$signup_code" != "200" ] || die "sign-up is still open. Check REGISTRATION_OPEN in $APP_DIR/.env and recreate."

# --- 8. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/healthchecks-$(date +%Y%m%d-%H%M%S).tar.gz" data .env
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	Healthchecks is running at https://${DOMAIN_HOST}/

	  1. Make your first check, then run the ping URL by hand once. A check that
	     has never been pinged has never proved anything.
	  2. Break one on purpose: set a period of one minute and do not ping it.
	     If no mail arrives, your relay is the problem, not Healthchecks.
	  3. This monitor runs on this server. It cannot tell you that this server
	     is down. Keep one free external check pointed at ${DOMAIN_HOST}.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
