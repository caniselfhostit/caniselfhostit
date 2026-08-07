#!/usr/bin/env bash
# Fider · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=feedback.example.com \
#   EMAIL_NOREPLY=noreply@example.com \
#   SMTP_HOST=smtp.example.com SMTP_USERNAME=apikey SMTP_PASSWORD=... ./install.sh
#
# SMTP_PASSWORD is read from the environment and never written to your terminal.
# Start that command line with a space if your shell records history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.fider.io/hosting-instance
#   https://docs.fider.io/how-to-enable-ssl
#   https://github.com/getfider/fider/blob/v0.36.0/app/pkg/env/env.go
#   https://github.com/getfider/fider/blob/v0.36.0/app/cmd/routes.go
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the token-signing key. Both go into /srv/fider/.env with mode 600 and neither
# is ever printed.
#
# DOMAIN_HOST is also BASE_URL, the address inside every sign-in link this
# instance mails. Choose it once. Changing it later invalidates links people
# are already holding.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/fider}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
EMAIL_NOREPLY="${EMAIL_NOREPLY:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USERNAME="${SMTP_USERNAME:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. feedback.example.com"
[ -n "$EMAIL_NOREPLY" ] || die "set EMAIL_NOREPLY; Fider requires a from-address and will not start without one"
[ -n "$SMTP_HOST" ] || die "set SMTP_HOST; sign-in links arrive by mail and there is no other way in"
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

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex for both. The database password rides inside a connection string, where
# hex needs no escaping, and 64 bytes of it clears the 512 bits upstream's own
# secret generator recommends for JWT_SECRET. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|JWT_SECRET' /srv/fider/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASE_URL=https://${DOMAIN_HOST}
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		JWT_SECRET=$(openssl rand -hex 64)
		SIGNUP_DISABLED=false
		EMAIL_NOREPLY=${EMAIL_NOREPLY}
		EMAIL_SMTP_HOST=${SMTP_HOST}
		EMAIL_SMTP_PORT=${SMTP_PORT}
		EMAIL_SMTP_USERNAME=${SMTP_USERNAME}
		EMAIL_SMTP_PASSWORD=${SMTP_PASSWORD}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-fider"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8181 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8181 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The image runs `fider migrate` before the server listens, so a first boot
# takes minutes rather than seconds.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/_health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/_health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/_health answered ${code:-nothing}. Check: docker compose logs --tail 60 fider"

curl -sS "https://${DOMAIN_HOST}/_health" | grep -q '"status":"Healthy"' \
	|| die "/_health answered 200 without status Healthy. Check: docker compose logs --tail 60 fider"

# With no board created yet, Fider redirects the bare hostname to its installer.
root_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$root_code" = "307" ] || die "https://${DOMAIN_HOST}/ returned ${root_code}, not the 307 an uninstalled Fider sends"

installer="$(curl -sS "https://${DOMAIN_HOST}/signup" | grep -c 'Sign up for Fider and let your customers share' || true)"
[ "$installer" = "1" ] || die "https://${DOMAIN_HOST}/signup did not render the expected first screen"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U fider -d fider | gzip > "$APP_DIR/backups/fider-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/fider-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/fider-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Fider is answering at https://${DOMAIN_HOST}/signup

	  1. Open that page, fill in your name, your email and the name of the
	     board, and submit. Fider mails you a confirmation link; that mail
	     arriving is the only proof your relay works. Until you follow the
	     link, every page reads "Pending Activation". If it never lands, read
	       docker compose logs --tail 60 fider
	     and check the from-address your relay will accept.
	  2. The installer is still open, which on a public hostname is a board
	     anyone who finds your address can claim. Once your board exists,
	     close it:
	       cd $APP_DIR
	       sudo sed -i 's/^SIGNUP_DISABLED=false\$/SIGNUP_DISABLED=true/' .env
	       docker compose up -d --force-recreate fider
	     Then confirm: curl -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/signup
	     must print 404, and https://${DOMAIN_HOST}/ must print 200.
	  3. Your two secrets are in $APP_DIR/.env, mode 600. Neither was printed
	     here. JWT_SECRET signs every session and sign-in link, so back up
	     .env with the database, not separately.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
