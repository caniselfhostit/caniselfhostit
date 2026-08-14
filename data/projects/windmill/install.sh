#!/usr/bin/env bash
# Windmill · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=wm.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream sources:
#   https://github.com/windmill-labs/windmill/blob/v1.789.0/docker-compose.yml
#   https://github.com/windmill-labs/windmill/blob/v1.789.0/README.md
#   https://github.com/windmill-labs/windmill/blob/v1.789.0/LICENSE
#   https://www.windmill.dev/docs/advanced/security_isolation
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the replacement superadmin password. Both go into /srv/windmill/.env with mode
# 600 and neither is ever printed.
#
# Windmill seeds one superadmin, admin@windmill.dev, with the password changeme.
# This script logs in with it once, replaces the password with the generated one,
# and then proves the old one is dead before it takes a backup.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/windmill}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
WM_ADMIN_EMAIL="admin@windmill.dev"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# Status code of a request, or 000 when the connection itself failed. Wrapped in
# an `if` so that a refused connection during the boot wait does not abort the
# script under `set -e`.
http_code() {
	local c
	if ! c="$(curl -sS -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)"; then c="000"; fi
	printf '%s' "$c"
}

# Prints a session token on a successful login and nothing at all otherwise.
# The token never reaches stdout of the script itself.
api_login() {
	local out code
	out="$(curl -sS -w '\n%{http_code}' -X POST "https://${DOMAIN_HOST}/api/auth/login" \
		-H 'Content-Type: application/json' \
		--data "{\"email\":\"${WM_ADMIN_EMAIL}\",\"password\":\"$1\"}" 2>/dev/null)"
	code="$(printf '%s' "$out" | tail -n1)"
	if [ "$code" = "200" ]; then printf '%s' "$out" | sed '$d'; fi
}

# Status code of a login attempt, used for the replay assert.
api_login_code() {
	http_code -X POST "https://${DOMAIN_HOST}/api/auth/login" \
		-H 'Content-Type: application/json' \
		--data "{\"email\":\"${WM_ADMIN_EMAIL}\",\"password\":\"$1\"}"
}

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. wm.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v curl >/dev/null 2>&1 || die "curl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; a server, a worker and PostgreSQL want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 30 ] || die "only ${avail_gb} GB free on /srv; the worker image alone unpacks to several GB and the worker warns under 15 GB free"

if ! resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')"; then resolved=""; fi
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: one travels inside a PostgreSQL connection
# string and the other inside a JSON request body, and neither wants escaping.
# Read the admin password later with
#   sudo grep WM_ADMIN_PASSWORD /srv/windmill/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DB_PASSWORD=$(openssl rand -hex 32)
		WM_ADMIN_PASSWORD=$(openssl rand -hex 32)
		BASE_URL=https://${DOMAIN_HOST}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-windmill"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8193 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8193 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The pull is well over a gigabyte: one image carries Python, Bun, Deno, Go,
# PHP, Java, Ruby, .NET and PowerShell. The server runs the database migrations
# on the way up, and a fresh database has a lot of them.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/version"
code=""
for _ in $(seq 1 60); do
	code="$(http_code "https://${DOMAIN_HOST}/api/version")"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "$code" = "200" ] || die "/api/version answered ${code}. Check: docker compose logs --tail 40 windmill_server"

echo "==> waiting for the worker to register"
alive=""
for _ in $(seq 1 30); do
	if health="$(curl -sS "https://${DOMAIN_HOST}/api/health/status" 2>/dev/null)"; then
		alive="$(printf '%s' "$health" | tr ',' '\n' | sed -n 's/.*"workers_alive":\([0-9]*\).*/\1/p')"
	else
		alive=""
	fi
	[ -n "$alive" ] && [ "$alive" -ge 1 ] && break
	sleep 10
done
[ -n "$alive" ] && [ "$alive" -ge 1 ] || die "no worker has pinged the database. Check: docker compose logs --tail 40 windmill_worker"
echo "==> workers_alive=${alive}"

# --- 7. Rotate the seeded superadmin, then prove the old one is dead ----------

if ! WM_ADMIN_PASSWORD="$(sudo grep '^WM_ADMIN_PASSWORD=' "$APP_DIR/.env" | cut -d= -f2-)"; then WM_ADMIN_PASSWORD=""; fi
[ -n "$WM_ADMIN_PASSWORD" ] || die "WM_ADMIN_PASSWORD is missing from $APP_DIR/.env"

TOKEN="$(api_login "$WM_ADMIN_PASSWORD")"
if [ -z "$TOKEN" ]; then
	TOKEN="$(api_login changeme)"
	[ -n "$TOKEN" ] || die "neither the generated password nor the seeded default logs in as ${WM_ADMIN_EMAIL}. Someone has already changed it, or the database is not the one this install created."
	set_code="$(http_code -X POST "https://${DOMAIN_HOST}/api/users/setpassword" \
		-H "Authorization: Bearer ${TOKEN}" \
		-H 'Content-Type: application/json' \
		--data "{\"password\":\"${WM_ADMIN_PASSWORD}\"}")"
	[ "$set_code" = "200" ] || die "/api/users/setpassword answered ${set_code}, not 200. The default password is still live. Stop and investigate."
	TOKEN="$(api_login "$WM_ADMIN_PASSWORD")"
	[ -n "$TOKEN" ] || die "the new password does not log in after the rotation reported success. Stop and investigate."
fi

replay="$(api_login_code changeme)"
[ "$replay" = "400" ] || die "replaying the default password returned ${replay}, not the 400 upstream returns for Invalid login. The default credential may still work. Stop and investigate."
echo "==> default credential replay: ${replay} (Invalid login)"

unauth="$(http_code "https://${DOMAIN_HOST}/api/users/whoami")"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."
echo "==> unauthenticated /api/users/whoami: ${unauth}"

if ! accounts="$(curl -sS -H "Authorization: Bearer ${TOKEN}" \
	"https://${DOMAIN_HOST}/api/users/list_as_super_admin?page=1&per_page=100" \
	| grep -o '"email":"[^"]*"' | sort -u | wc -l | tr -d ' ')"; then accounts="0"; fi
[ "$accounts" = "1" ] || die "this instance has ${accounts} accounts, not 1. Windmill seeds exactly one; anything else means somebody else got here first."
echo "==> accounts on this instance: ${accounts}"

# --- 8. One workspace and one job, which is the product working --------------

if curl -sS -H "Authorization: Bearer ${TOKEN}" "https://${DOMAIN_HOST}/api/workspaces/list" | grep -q '"id":"main"'; then
	echo "==> workspace main already exists"
else
	created="$(curl -sS -X POST "https://${DOMAIN_HOST}/api/workspaces/create" \
		-H "Authorization: Bearer ${TOKEN}" \
		-H 'Content-Type: application/json' \
		--data '{"id":"main","name":"Main"}')"
	case "$created" in
		*"Created workspace main"*) echo "==> $created" ;;
		*) die "creating the main workspace answered: ${created}" ;;
	esac
fi

echo "==> running one bash job end to end"
result=""
for _ in $(seq 1 5); do
	result="$(curl -sS -X POST "https://${DOMAIN_HOST}/api/w/main/jobs/run_wait_result/preview" \
		-H "Authorization: Bearer ${TOKEN}" \
		-H 'Content-Type: application/json' \
		--data '{"language":"bash","content":"echo windmill-selfhost-check","args":{}}')"
	case "$result" in *windmill-selfhost-check*) break ;; esac
	sleep 15
done
case "$result" in
	*windmill-selfhost-check*) echo "==> job result: ${result}" ;;
	*) die "the smoke-test job returned: ${result}. Check: docker compose logs --tail 40 windmill_worker" ;;
esac

# --- 9. The first backup, before day one ends --------------------------------
#
# pg_dump, not a tar of postgres/: copying a live data directory is not a
# backup. The named volumes hold language caches and spilled job logs, both of
# which rebuild, so they are deliberately not archived.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U windmill -d windmill | gzip > "$APP_DIR/backups/windmill-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/windmill-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/windmill-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/windmill-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Windmill is answering at https://${DOMAIN_HOST}

	  1. Sign in as ${WM_ADMIN_EMAIL}. The password is in $APP_DIR/.env, mode
	     600, and was never printed here. Read it with
	       sudo grep WM_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager now. There is no SMTP configured,
	     so there is no password reset link if you lose it.
	  2. The seeded default password was replaced and then replayed against
	     /api/auth/login, which answered 400 Invalid login. This instance has
	     exactly one account and no open registration.
	  3. Your workspace is main. A bash job ran through it end to end and came
	     back with windmill-selfhost-check, which means the server queued it and
	     the worker executed it.
	  4. Job isolation is off, which is the image default. A script running here
	     can read the worker's environment, and that environment holds the
	     database URL. Treat a script from the hub the way you treat a shell
	     script from a stranger.
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
