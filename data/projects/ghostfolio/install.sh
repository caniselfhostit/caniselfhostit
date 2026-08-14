#!/usr/bin/env bash
# Ghostfolio · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=portfolio.example.com ./install.sh
#
# Authored by caniselfhostit from upstream's own packaging at tag 3.50.0:
#   https://github.com/ghostfolio/ghostfolio/blob/3.50.0/docker/docker-compose.yml
#   https://github.com/ghostfolio/ghostfolio/blob/3.50.0/README.md
#   https://github.com/ghostfolio/ghostfolio/blob/3.50.0/docker/entrypoint.sh
#
# Four secrets are generated here, on this machine: the PostgreSQL password,
# the Redis password, ACCESS_TOKEN_SALT and JWT_SECRET_KEY. All four go into
# /srv/ghostfolio/.env with mode 600 and none is ever printed.
#
# This script also creates the first Ghostfolio account, which upstream gives
# the ADMIN role, then turns account creation off and proves it is off. The
# security token for that account is written to /srv/ghostfolio/security-token.txt
# with mode 600. It is the only way in: the account has no email address and
# no password, and nothing here can reset it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/ghostfolio}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. portfolio.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; this stack wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The PostgreSQL image chowns its own data directory on first start, so that
# one stays owned by root. Ghostfolio itself needs no volume: every account,
# activity and cached price is a row in PostgreSQL, and Redis holds cache and
# job queues that rebuild themselves.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex rather than base64 for all four: the database password is pasted into a
# connection URL, where + and / would have to be percent-encoded. Read them
# later with
#   sudo grep -E 'POSTGRES_PASSWORD|REDIS_PASSWORD|ACCESS_TOKEN_SALT|JWT_SECRET_KEY' /srv/ghostfolio/.env
#
# ACCESS_TOKEN_SALT is what hashes the security token below. A database
# restored beside a different .env accepts nobody.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		ROOT_URL=https://${DOMAIN_HOST}
		POSTGRES_DB=ghostfolio
		POSTGRES_USER=ghostfolio
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
		ACCESS_TOKEN_SALT=$(openssl rand -hex 32)
		JWT_SECRET_KEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-ghostfolio"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8196, 5432 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8196, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The entrypoint applies 117 Prisma migrations and a seed before the server
# answers anything, so the first boot takes minutes.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/v1/health answered ${code:-nothing}. Check: docker compose logs --tail 40 ghostfolio"

curl -sS "https://${DOMAIN_HOST}/api/v1/health" | grep -q '"status":"OK"' \
	|| die "health answered 200 without status OK. Check: docker compose logs --tail 40 ghostfolio"

curl -sS "https://${DOMAIN_HOST}/en" | grep -q '<title>Ghostfolio' \
	|| die "the client did not render. Check: docker compose logs --tail 40 ghostfolio"

# --- 7. Claim the instance, then close it ------------------------------------
#
# Account creation is open on a fresh install and the first account created
# gets the ADMIN role, so this runs immediately after the server answers.

umask 077
curl -sS -X POST "https://${DOMAIN_HOST}/api/v1/user" -o "$APP_DIR/first-user.json"
grep -q '"role":"ADMIN"' "$APP_DIR/first-user.json" \
	|| die "the new account is not ADMIN, so somebody else claimed this hostname first. Stop and investigate."
grep -o '"accessToken":"[^"]*"' "$APP_DIR/first-user.json" | cut -d'"' -f4 > "$APP_DIR/security-token.txt"
chmod 600 "$APP_DIR/first-user.json" "$APP_DIR/security-token.txt"
umask 022
[ "$(wc -c < "$APP_DIR/security-token.txt")" -eq 129 ] || die "the security token is not 128 characters. Stop and investigate."

put="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
	-H "Authorization: Bearer $(grep -o '"authToken":"[^"]*"' "$APP_DIR/first-user.json" | cut -d'"' -f4)" \
	-H 'Content-Type: application/json' -d '{"value":"false"}' \
	"https://${DOMAIN_HOST}/api/v1/admin/settings/IS_USER_SIGNUP_ENABLED" || true)"
[ "$put" = "200" ] || die "disabling account creation returned ${put}, not 200. Stop and investigate."

signup="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/v1/user" || true)"
[ "$signup" = "403" ] || die "account creation still answers ${signup}, not 403. The instance is open. Stop."

advertised="$(curl -sS "https://${DOMAIN_HOST}/api/v1/info" | grep -c createUserAccount || true)"
[ "$advertised" = "0" ] || die "the info endpoint still advertises createUserAccount. The instance is open. Stop."

rm -f "$APP_DIR/first-user.json"

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U ghostfolio -d ghostfolio | gzip > "$APP_DIR/backups/ghostfolio-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/ghostfolio-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env security-token.txt -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/ghostfolio-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Ghostfolio is answering at https://${DOMAIN_HOST}

	  1. Your security token is in $APP_DIR/security-token.txt, mode 600.
	     Read it with
	       sudo cat $APP_DIR/security-token.txt
	     and put it in your password manager now. It was not printed here.
	     Open https://${DOMAIN_HOST}, press Sign in, and paste it. That token
	     is the only way in: this account has no email address, no password,
	     and no reset.
	  2. Account creation was open for the few seconds between start-up and
	     step 7. It is closed now: an unauthenticated POST to /api/v1/user
	     answers 403 and /api/v1/info no longer advertises createUserAccount.
	  3. Market prices come from public sources, mainly Yahoo Finance. If
	     holdings show no value, ask
	       https://${DOMAIN_HOST}/api/v1/health/data-provider/YAHOO
	     200 means the source answered, 503 means it is rate-limiting. Neither
	     is something this install can fix.
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     config archive holding compose.yml, .env, the security token and the
	     live Caddyfile. They travel together, because the token is stored
	     hashed with ACCESS_TOKEN_SALT from .env. They are also on the same
	     disk as the data, which is not a backup. Copy them off tonight.

DONE
