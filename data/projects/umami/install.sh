#!/usr/bin/env bash
# Umami · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=stats.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.umami.is/docs/install
#   https://docs.umami.is/docs/environment-variables
#   https://docs.umami.is/docs/guides/hosting
#   https://docs.umami.is/docs/api/authentication
#   https://docs.umami.is/docs/login
#
# Three secrets are generated here, on this machine: the PostgreSQL password,
# the token-signing APP_SECRET, and the password that replaces the one the image
# ships on its built-in admin account. All three go into /srv/umami/.env with
# mode 600 and none of them is ever printed.
#
# DOMAIN_HOST ends up inside the tracking snippet on every page you measure, so
# changing it later means editing every one of those pages.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/umami}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. stats.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; Node plus PostgreSQL wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64 for all three: two of them travel inside a URL and the
# third inside a JSON body, and hex needs no escaping in either. Read the admin
# password later with
#   grep ADMIN_PASSWORD /srv/umami/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DB_PASSWORD=$(openssl rand -hex 32)
		APP_SECRET=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-umami"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8105 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8105 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Umami applies its own schema migrations on the way up, and that is also what
# creates the built-in admin account that section 7 immediately takes over.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/heartbeat"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/heartbeat" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/heartbeat answered ${code:-nothing}. Check: docker compose logs --tail 40 umami"

curl -sS "https://${DOMAIN_HOST}/api/heartbeat" | grep -q '"ok":true' \
	|| die "/api/heartbeat answered 200 without ok:true. Check: docker compose logs --tail 40 umami"

curl -sS "https://${DOMAIN_HOST}/login" | grep -q '<title>Login | Umami</title>' \
	|| die "the login page did not carry the expected title. Check: docker compose logs --tail 40 umami"

# --- 7. Take the shipped credential away -------------------------------------
#
# Upstream documents a built-in account with a fixed published password. Until
# the next few lines run, that is a known credential on a public hostname.

login="$(curl -sS -X POST "https://${DOMAIN_HOST}/api/auth/login" \
	-H 'Content-Type: application/json' \
	--data '{"username":"admin","password":"umami"}' || true)"
token="$(printf '%s' "$login" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
userid="$(printf '%s' "$login" | sed -n 's/.*"user":{"id":"\([^"]*\)".*/\1/p')"
[ -n "$token" ] && [ -n "$userid" ] || die "could not sign in with the shipped credential; nothing was changed"

changed="$(printf '{"password":"%s"}' "$(awk -F= '/^ADMIN_PASSWORD/{print $2}' "$APP_DIR/.env")" \
	| curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/users/${userid}" \
		-H "Authorization: Bearer ${token}" \
		-H 'Content-Type: application/json' \
		--data-binary @- || true)"
[ "$changed" = "200" ] || die "the password update returned ${changed}, not 200. The shipped credential is still live."

stale="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://${DOMAIN_HOST}/api/auth/login" \
	-H 'Content-Type: application/json' \
	--data '{"username":"admin","password":"umami"}' || true)"
[ "$stale" = "401" ] || die "the shipped credential still returns ${stale}, not 401. Stop and investigate."
unset login token userid

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U umami -d umami | gzip > "$APP_DIR/backups/umami-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/umami-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/umami-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Umami is answering at https://${DOMAIN_HOST}/login

	  1. The account the image ships with had a published password. It has been
	     changed, and a sign-in with the old one was checked and refused.
	  2. Your admin password is in $APP_DIR/.env, mode 600. Read it with
	       grep ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and it
	     never appeared on a command line. The username is admin.
	  3. Nothing is counted yet. Sign in, add a website, and paste the tracking
	     snippet it gives you into the <head> of the pages you want measured.
	     The address in that snippet is https://${DOMAIN_HOST}, so keep the
	     hostname.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
