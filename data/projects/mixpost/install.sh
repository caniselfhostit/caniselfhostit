#!/usr/bin/env bash
# Mixpost Lite · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=mixpost.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.mixpost.app/lite/installation/docker
#   https://docs.mixpost.app/lite/configuration/environment-variables
#   https://docs.mixpost.app/troubleshooting
#   https://hub.docker.com/_/mysql
#
# Four secrets are generated here, on this machine: the Laravel application key
# that encrypts every stored social token, the database password, the MySQL root
# password, and the password this script sets on the account the container
# creates. All four go into /srv/mixpost/.env with mode 600 and none is printed.
#
# The container seeds a user admin@example.com with the password upstream prints
# in its own install guide. This script signs in with that password once, over
# loopback, replaces it with the generated one, and then proves the published
# default no longer works. Do not change that account's email address afterwards:
# the container recreates admin@example.com, with the published password, on any
# start where that row is missing.
#
# DOMAIN_HOST is the host inside every OAuth redirect URI you will register at X
# and at Meta. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/mixpost}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
BASE="http://127.0.0.1:8197"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }
csrf() { sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p'; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. mixpost.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; three containers with MySQL among them want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 "$APP_DIR/storage" "$APP_DIR/logs"
sudo install -d -m 700 "$APP_DIR/mysql" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# The application config file that makes Laravel believe Caddy's
# X-Forwarded-Proto. It has to exist before the first start, or Docker creates a
# directory at that mount path instead of a file.
cat > "$APP_DIR/trustedproxy.php" <<'PHPFILE'
<?php
// Mixpost Lite · trusted proxies. Authored by caniselfhostit from the image's
// vendor/laravel/framework/src/Illuminate/Http/Middleware/TrustProxies.php,
// which trusts nothing unless the application sets a proxy list, which this
// image does not, or config('trustedproxy.proxies') exists, which is this
// file. Without it Laravel reads Caddy's plain http connection and hands the
// browser http:// URLs on an https page, the Ziggy route table the dashboard
// drives itself from included, and browsers block those.
//
// '*' trusts the address that connected, which behind a loopback-only
// published port is only ever the Caddy on this host.

return [
    'proxies' => '*',
];
PHPFILE
chmod 644 "$APP_DIR/trustedproxy.php"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Read them later with
#   sudo cat /srv/mixpost/.env
# APP_KEY is a Laravel key for AES-256-CBC, which is 32 random bytes in base64.
# Upstream offers a web page that generates one; this makes its own instead,
# because a key fetched from someone else's website is a key someone else saw.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		MIXPOST_DOMAIN=${DOMAIN_HOST}
		APP_KEY=base64:$(openssl rand -base64 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
		ADMIN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-mixpost"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8197, 3306 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8197, 3306 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start is the slow one: MySQL initialises its data directory, then
# the Mixpost container waits for it and runs every Laravel migration.

docker compose pull
docker compose up -d

echo "==> waiting for ${BASE}/mixpost/login (up to seven minutes)"
code=""
for _ in $(seq 1 42); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/mixpost/login" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "$code" = "200" ] || die "the sign-in page answered ${code:-nothing}. Check: docker compose logs --tail 40 mixpost"

curl -sS "https://${DOMAIN_HOST}/mixpost/login" | grep -q 'Log in' \
	|| die "the sign-in page did not come through Caddy. Check: sudo caddy validate --config /etc/caddy/Caddyfile"

horizon="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/horizon")"
[ "$horizon" = "403" ] || die "/horizon answered ${horizon}, not 403. The queue dashboard is meant to refuse anonymous callers."

dash="$(curl -sS -o /dev/null -w '%{redirect_url}' "https://${DOMAIN_HOST}/mixpost")"
[ "$dash" = "https://${DOMAIN_HOST}/mixpost/login" ] \
	|| die "/mixpost redirected to '${dash}', not https://${DOMAIN_HOST}/mixpost/login. An http:// target means trustedproxy.php did not load."

# --- 7. Close the door the image leaves open ---------------------------------
#
# start.sh inside the image runs `mixpost-auth:create --admin` on every start
# where no row with the address admin@example.com exists, and that command sets
# the password upstream prints in its install guide. Sign in with it once, over
# loopback, swap it for the generated one, then prove the published one is dead.

umask 077
printf '%s' "$(grep '^ADMIN_PASSWORD' "$APP_DIR/.env" | cut -d= -f2-)" > "$APP_DIR/.newpw"
JAR="$APP_DIR/.jar"
rm -f "$JAR"

T1="$(curl -sS -c "$JAR" "${BASE}/mixpost/login" | csrf)"
[ -n "$T1" ] || die "no CSRF token on the sign-in page. Stop and read it: curl -sS ${BASE}/mixpost/login"

first="$(curl -sS -b "$JAR" -c "$JAR" -o /dev/null -w '%{redirect_url}' -X POST "${BASE}/mixpost/login" \
	--data-urlencode "_token=${T1}" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme')"
[ "$first" = "${BASE}/mixpost" ] \
	|| die "signing in as the seeded account sent us to '${first}'. Expected ${BASE}/mixpost. Stop and investigate before anything else."
echo "==> the seeded account signed in, which is exactly the door being closed now"

T2="$(curl -sS -b "$JAR" -c "$JAR" "${BASE}/mixpost/profile" | csrf)"
[ -n "$T2" ] || die "no CSRF token on the profile page; the session did not carry."

curl -sS -b "$JAR" -c "$JAR" -o /dev/null -X PUT "${BASE}/mixpost/profile/password" \
	--data-urlencode "_token=${T2}" --data-urlencode 'current_password=changeme' \
	--data-urlencode "password@${APP_DIR}/.newpw" --data-urlencode "password_confirmation@${APP_DIR}/.newpw"

rm -f "$JAR"
T3="$(curl -sS -c "$JAR" "${BASE}/mixpost/login" | csrf)"
after="$(curl -sS -b "$JAR" -c "$JAR" -o /dev/null -w '%{redirect_url}' -X POST "${BASE}/mixpost/login" \
	--data-urlencode "_token=${T3}" --data-urlencode 'email=admin@example.com' --data-urlencode 'password=changeme')"
rm -f "$JAR" "$APP_DIR/.newpw"
umask 022
[ "$after" = "${BASE}/mixpost/login" ] \
	|| die "the published default still signs in (redirect '${after}'). The rotation failed. Stop and do it by hand in the browser."
echo "==> the published default is refused and bounced back to the sign-in page"

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mysql sh -c 'exec mysqldump -u mixpost -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces mixpost' \
	| gzip > "$APP_DIR/backups/mixpost-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/mixpost-files-${STAMP}.tar.gz" \
	-C "$APP_DIR" compose.yml .env trustedproxy.php storage logs -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/mixpost-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Mixpost Lite is answering at https://${DOMAIN_HOST}/mixpost/login

	  1. Sign in as admin@example.com. The password was generated here and is
	     in $APP_DIR/.env, mode 600. Read it with
	       sudo grep ADMIN_PASSWORD $APP_DIR/.env
	     It was not printed above. Put it in your password manager now: this
	     install has no mail configured, so there is no password reset.
	  2. Do not change that account's email address. The container recreates
	     admin@example.com with upstream's published password on any start
	     where that address is missing from the users table. Change the display
	     name and the password as much as you like; leave the address alone.
	  3. No social account is connected, and this script cannot connect one.
	     Mixpost Lite publishes to Facebook Pages, X and Mastodon, and the
	     first two need an app you register in that company's own developer
	     portal, with a callback of
	       https://${DOMAIN_HOST}/mixpost/callback/facebook
	       https://${DOMAIN_HOST}/mixpost/callback/twitter
	     and its id and secret entered under Settings, Services. Mastodon is
	     the exception: Mixpost registers that application itself against the
	     instance you name.
	  4. First backup written to $APP_DIR/backups: a database dump and a file
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
