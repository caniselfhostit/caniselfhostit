#!/usr/bin/env bash
# Twenty · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=crm.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.twenty.com/developers/self-host/capabilities/docker-compose
#   https://docs.twenty.com/developers/self-host/capabilities/setup
#   https://github.com/twentyhq/twenty/blob/064bdd79/packages/twenty-docker/docker-compose.yml
#
# Three secrets are generated here, on this machine: ENCRYPTION_KEY, which
# encrypts stored secrets at rest, APP_SECRET, which the token code still reaches
# for, and the PostgreSQL password. All three go into /srv/twenty/.env with mode
# 600 and none of them is ever printed.
#
# DOMAIN_HOST is also SERVER_URL, which upstream says must match how people reach
# the application in a browser.
#
# This script cannot create the first workspace, because only a browser can. It
# stops with the signup form still open and tells you to go and claim it, and it
# prints the one command that proves the form is shut afterwards. Until you run
# that, whoever loads the hostname first owns this instance.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/twenty}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. crm.example.com"
case "$DOMAIN_HOST" in
	*/*) die "DOMAIN_HOST is a hostname, not a URL: no scheme and no trailing slash" ;;
esac
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; two Node processes plus PostgreSQL and Redis want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# Three owners, on purpose. The application image runs as uid 1000, so it cannot
# write an attachment directory owned by the login user. The PostgreSQL image
# chowns its own data directory on first start, so that one stays with root.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/storage"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Read them later with
#   sudo grep -E 'ENCRYPTION_KEY|APP_SECRET' /srv/twenty/.env
# Upstream says losing ENCRYPTION_KEY means losing access to every secret stored
# in the database, so put it in a password manager the day you run this. The
# database password is hex because it rides inside a connection string, where
# upstream asks for no special characters.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SERVER_URL=https://${DOMAIN_HOST}
		IS_MULTIWORKSPACE_ENABLED=false
		APP_SECRET=$(openssl rand -base64 32)
		ENCRYPTION_KEY=$(openssl rand -base64 32)
		PG_DATABASE_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-twenty"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8183, 5432 and 6379 are none of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8183, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The server container runs the schema setup and every migration before it
# answers a request, so the first boot is minutes rather than seconds. The worker
# waits on the server's own health check before it starts.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthz (a first boot can take ten minutes)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthz" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/healthz answered ${code:-nothing}. Check: docker compose logs --tail 60 server"

curl -sS "https://${DOMAIN_HOST}/healthz" | grep -q '"status":"ok"' \
	|| die "/healthz answered 200 without status ok. Check: docker compose logs --tail 60 server"

# The title the served page carries. Its absence means Caddy is reaching
# something other than Twenty.
curl -sSL "https://${DOMAIN_HOST}/" | grep -q '<title>Twenty</title>' \
	|| die "the page at https://${DOMAIN_HOST}/ does not carry the Twenty title"

# Single-workspace mode is what makes the first signup final: upstream disables
# new signups once the first workspace exists.
curl -sS "https://${DOMAIN_HOST}/client-config" | grep -q '"isMultiWorkspaceEnabled":false' \
	|| die "client-config does not report isMultiWorkspaceEnabled false. Stop and investigate."

# All four services have to be up, and the worker is the one nobody notices.
docker compose ps --format '{{.Service}} {{.State}}'
running="$(docker compose ps --format '{{.Service}} {{.State}}' | awk '$2 == "running"' | wc -l | tr -d ' ')"
[ "$running" = "4" ] || die "only ${running} of 4 services report running. Check: docker compose ps"

# --- 7. The closure check, written out for the human ------------------------
#
# This cannot run yet: with no workspace, the signup mutation would create the
# very account it is meant to refuse. It is written to a file, and the summary
# below says when to run it. Until it prints "signup closed", the instance
# belongs to whoever loads the hostname first.

cat > "$APP_DIR/check-signup-closed.sh" <<'PROBE'
#!/usr/bin/env bash
# Run this only after the first account and workspace exist. It asks the public
# signup mutation for a second account on an address nobody owns. Upstream
# refuses with SIGNUP_DISABLED once one workspace exists.
set -euo pipefail
HOST="${1:?usage: ./check-signup-closed.sh crm.example.com}"
curl -sS -X POST "https://${HOST}/graphql" -H 'content-type: application/json' \
	--data '{"query":"mutation Probe($e: String!, $p: String!) { signUp(email: $e, password: $p) { tokens { refreshToken { token } } } }","variables":{"e":"closure-probe@example.com","p":"probe-not-a-login"}}' \
	-o /tmp/twenty-signup-probe.json
cat /tmp/twenty-signup-probe.json
echo
grep -q 'SIGNUP_DISABLED' /tmp/twenty-signup-probe.json \
	|| { echo "signup is still OPEN and that reply may be a new account. Finish the workspace screen, then run this again." >&2; exit 1; }
echo "signup closed"
PROBE
chmod +x "$APP_DIR/check-signup-closed.sh"

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U twenty -d default | gzip > "$APP_DIR/backups/twenty-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/twenty-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/twenty-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/twenty-files-${STAMP}.tar.gz" ] || die "the file archive is empty"

cat <<-DONE

	Twenty is answering at https://${DOMAIN_HOST}

	  1. Do this now, before anything else: open https://${DOMAIN_HOST}, create
	     your account, and keep going until the workspace exists and the records
	     screen has loaded. Until that workspace exists, the signup form belongs
	     to whoever loads the hostname first. Save the password you choose: no
	     mail is configured, so the reset link has nothing to send.
	  2. Then prove the form is shut, and do not skip this. Run:
	       $APP_DIR/check-signup-closed.sh ${DOMAIN_HOST}
	     It prints the server's reply and then "signup closed". If it says signup
	     is still OPEN, an account was created and your instance is still open to
	     strangers: finish the workspace screen and run it again.
	  3. Your ENCRYPTION_KEY is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep ENCRYPTION_KEY $APP_DIR/.env
	     and put it in your password manager. It was not printed here. Upstream
	     says losing it loses every secret the database has encrypted under it.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/twenty/

DONE
