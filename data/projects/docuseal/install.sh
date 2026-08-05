#!/usr/bin/env bash
# DocuSeal · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=sign.example.com ADMIN_EMAIL=you@example.com \
#     RELAY_HOST=smtp.example.net RELAY_PORT=587 RELAY_USER=you@example.com ./install.sh
#
# It prompts once, silently, for the relay credential. That value is never
# echoed and never reaches your shell history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/docusealco/docuseal/blob/master/README.md
#   https://github.com/docusealco/docuseal/blob/master/config/database.yml
#   https://github.com/docusealco/docuseal/blob/master/config/environments/production.rb
#   https://caddyserver.com/docs/automatic-https
#
# One secret is generated here: SECRET_KEY_BASE. It is written to
# /srv/docuseal/.env with mode 600 and never printed. Do not change it later:
# the record encryption keys are derived from it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/docuseal}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
RELAY_HOST="${RELAY_HOST:-}"
RELAY_PORT="${RELAY_PORT:-587}"
RELAY_USER="${RELAY_USER:-$ADMIN_EMAIL}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. sign.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the first account will use"
[ -n "$RELAY_HOST" ]  || die "set RELAY_HOST to an SMTP relay you already have. Signing invitations are email."
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; this install wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image creates a docuseal account with uid 2000 and runs as it.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 2000 -g 2000 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. One generated secret, plus the relay credential you already own ------

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SECRET_KEY_BASE=$(openssl rand -hex 64)
		HOST=${DOMAIN_HOST}
		FORCE_SSL=${DOMAIN_HOST}
		SMTP_ADDRESS=${RELAY_HOST}
		SMTP_PORT=${RELAY_PORT}
		SMTP_DOMAIN=${DOMAIN_HOST}
		SMTP_USERNAME=${RELAY_USER}
		SMTP_ENABLE_STARTTLS=true
	ENVFILE
	printf 'SMTP_PASSWORD=' >> "$APP_DIR/.env"
	printf 'Relay credential for %s (input is hidden): ' "$RELAY_USER" > /dev/tty
	read -rs relay_value < /dev/tty
	printf '\n' > /dev/tty
	printf '%s\n' "$relay_value" >> "$APP_DIR/.env"
	unset relay_value
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

sudo awk -F= '/^SMTP_PASSWORD/ {print "relay credential recorded, length " length($2)}' "$APP_DIR/.env"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-docuseal"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8089 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8089 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it and prove it works ------------------------------------------
#
# Rails migrates on the first boot, so this takes a while the first time.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/up (Rails is migrating, Caddy is getting a certificate)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/up" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/up answered ${code:-nothing}. Check: docker compose logs --tail 40 docuseal"

setup_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/setup" || true)"
[ "$setup_code" = "200" ] || die "/setup answered ${setup_code}, so the first-run form is not there. Check the logs."

# --- 7. Create the first account, then prove the form closed -----------------

cat <<-SETUP

	Open https://${DOMAIN_HOST}/setup now and create the first account with
	${ADMIN_EMAIL}. Until you do, whoever finds this hostname can create it
	instead, and they would own every document you later put here.

SETUP
printf 'Press Return once you are signed in. '
read -r _

setup_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/setup" || true)"
echo "==> /setup now answers ${setup_code}"
[ "$setup_code" != "200" ] || die "/setup still answers 200, so no account exists yet. Create it before going on."

# --- 8. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

docker compose stop
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/docuseal-$(date +%Y%m%d-%H%M%S).tar.gz" data .env
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	DocuSeal is running at https://${DOMAIN_HOST}/

	  1. Send yourself a one-field document and sign it. If the invitation does
	     not arrive, your relay is the problem: DocuSeal is set not to raise
	     delivery errors, so the interface stays green while nothing is sent.
	  2. data/ and .env travel together. The documents are in data/, and the key
	     that decrypts the encrypted columns is derived from SECRET_KEY_BASE in
	     .env. One without the other is not a restore.
	  3. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight, and
	     somewhere you would still have after a fire: these are agreements other
	     people are relying on.

DONE
