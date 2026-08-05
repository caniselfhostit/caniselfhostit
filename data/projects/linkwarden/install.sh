#!/usr/bin/env bash
# Linkwarden · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=links.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.linkwarden.app/self-hosting/setup
#   https://docs.linkwarden.app/self-hosting/environment-variables
#   https://docs.linkwarden.app/self-hosting/reverse-proxy
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the NextAuth signing secret. Both go into /srv/linkwarden/.env with mode 600 and
# neither is ever printed.
#
# Registration is left open until you have created your own account, and this
# script stops and tells you to do that. It does not close it for you, because
# closing it before the account exists locks you out of your own install.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/linkwarden}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. links.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; page preservation runs a headless Chromium and wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; archives grow, and this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/data"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: the database password ends up inside a
# connection URL, where the base64 alphabet needs escaping. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|NEXTAUTH_SECRET' /srv/linkwarden/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXTAUTH_URL=https://${DOMAIN_HOST}/api/v1/auth
		NEXT_PUBLIC_DISABLE_REGISTRATION=false
		NEXTAUTH_SECRET=$(openssl rand -hex 32)
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-linkwarden"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8085 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8085 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot is slow. Prisma applies the whole schema before Next.js starts
# answering, so a 502 for the first few minutes is the normal case, not a fault.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/ (Prisma migrations, then a certificate)"
for _ in $(seq 1 60); do
	code="$(curl -sSL -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing} after ten minutes. Check: docker compose logs --tail 50 linkwarden"

curl -sSL "https://${DOMAIN_HOST}/" | grep -qi 'linkwarden' \
	|| die "the page answered 200 but does not mention Linkwarden. Check: docker compose logs linkwarden"

# --- 7. The first backup, before day one ends --------------------------------
#
# Two artifacts, because there are two kinds of state: the database holds the
# links and the account, the data directory holds the archived copies.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U postgres -d postgres | gzip > "$APP_DIR/backups/linkwarden-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/linkwarden-files-${STAMP}.tar.gz" data .env
ls -lh "$APP_DIR/backups/"

[ -s "$APP_DIR/backups/linkwarden-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Linkwarden is running at https://${DOMAIN_HOST}/

	  1. Open https://${DOMAIN_HOST}/register NOW and create your account.
	     Registration is open until you close it in step 2, so this window is
	     the one part of the install a stranger could walk into.
	  2. Then close it:
	       sed -i 's/^NEXT_PUBLIC_DISABLE_REGISTRATION=false$/NEXT_PUBLIC_DISABLE_REGISTRATION=true/' $APP_DIR/.env
	       cd $APP_DIR && docker compose down && docker compose up -d
	     A restart is not enough: the containers have to be recreated for a
	     changed .env to take effect. Then try to register a second account and
	     confirm it is refused.
	  3. Both secrets are in $APP_DIR/.env, mode 600. Read them with
	       sudo grep -E 'POSTGRES_PASSWORD|NEXTAUTH_SECRET' $APP_DIR/.env
	     and put them in your password manager. Neither was printed here.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
