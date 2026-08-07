#!/usr/bin/env bash
# Keila · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=news.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.keila.io/docs/installation
#   https://www.keila.io/docs/configuration
#   https://www.keila.io/docs/setup
#   https://github.com/pentacent/keila/blob/v0.30.2/priv/repo/seeds.exs
#
# Three secrets are generated here, on this machine: the PostgreSQL password, the
# Phoenix secret key base, and the root account's password. All three go into
# /srv/keila/.env with mode 600 and none of them is ever printed.
#
# This script runs in two passes on a fresh box. The first pass writes .env with
# the relay lines blank and stops, because Keila will not start without an SMTP
# relay and those four values are yours, not this script's. Fill them in, then
# run it again.
#
# DOMAIN_HOST is also URL_HOST, the hostname every unsubscribe link and opt-in
# confirmation link is built from. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/keila}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. news.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the root account will log in with"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

arch="$(dpkg --print-architecture)"
[ "$arch" = "amd64" ] || die "this box is ${arch}; the Keila image is published for linux/amd64 only"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Keila plus PostgreSQL wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 755 "$APP_DIR/uploads"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex for the database password and the key base, which upstream requires to be
# at least 64 characters; base64 for the root password, which a human types into
# a form. Read them later with
#   sudo grep -E 'SECRET_KEY_BASE|KEILA_PASSWORD' /srv/keila/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		SECRET_KEY_BASE=$(openssl rand -hex 48)
		URL_HOST=${DOMAIN_HOST}
		KEILA_USER=${ADMIN_EMAIL}
		KEILA_PASSWORD=$(openssl rand -base64 30)
		MAILER_SMTP_PORT=587
		MAILER_ENABLE_STARTTLS=true
		MAILER_SMTP_HOST=
		MAILER_SMTP_USER=
		MAILER_SMTP_FROM_EMAIL=
		MAILER_SMTP_PASSWORD=
		# the four blank lines above are the relay account, filled in by hand
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
	cat >&2 <<-RELAY

		Wrote $APP_DIR/.env with three generated secrets. Nothing was printed.

		Keila cannot work without an SMTP relay. Edit that file now
		(sudo nano $APP_DIR/.env) and fill in the relay hostname, the account
		name, the relay password and a sending address on a domain you control.
		Port 587 with STARTTLS is set already; a relay documenting 465 wants
		that port, MAILER_ENABLE_STARTTLS=false and MAILER_ENABLE_SSL=true.

		Then run this script again.

	RELAY
	exit 1
fi

# Every relay value must have a value: a blank one starts a Keila that cannot
# send, and an absent one halts the release at boot.
missing="$(sudo awk -F= '/^MAILER_SMTP_(HOST|USER|PASSWORD|FROM_EMAIL)=/ && length($2) == 0 {print $1}' "$APP_DIR/.env" | tr '\n' ' ')"
[ -z "$missing" ] || die "still blank in $APP_DIR/.env: ${missing}"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-keila"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8145 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8145 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The release migrates the database and seeds the root account on the way up.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/auth/login"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/auth/login" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/auth/login answered ${code:-nothing}. Check: docker compose logs --tail 40 keila"

curl -sS "https://${DOMAIN_HOST}/auth/login" | grep -q 'Sign in with your email address and password here.' \
	|| die "the login page did not carry its first-screen line. Check: docker compose logs --tail 40 keila"

# The sign-up form must be shut: this hostname is public.
curl -sS "https://${DOMAIN_HOST}/auth/register" | grep -q 'Registration disabled.' \
	|| die "/auth/register is still open. DISABLE_REGISTRATION did not take effect."

# The API must refuse a call with no bearer token. Upstream answers 403.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/contacts" || true)"
[ "$unauth" = "403" ] || die "an unauthenticated API call returned ${unauth}, not 403. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U keila -d keila | gzip > "$APP_DIR/backups/keila-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/keila-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/keila-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Keila is answering at https://${DOMAIN_HOST}/auth/login

	  1. Your root account is ${ADMIN_EMAIL}. Its password is in $APP_DIR/.env,
	     mode 600. Read it with
	       sudo grep KEILA_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  2. Sign-up is closed: /auth/register answers with a registration-disabled
	     page, so this public hostname hands accounts to nobody.
	  3. Mail is two settings, not one. The relay in .env carries system mail.
	     Campaigns go out as a sender you add inside a project in the web
	     interface. Send one campaign to yourself before importing anybody.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. Both are on the same disk as the data, which is not a backup,
	     and the archive holds .env, so treat it like a password-manager export.
	     Copy them somewhere else tonight.

DONE
