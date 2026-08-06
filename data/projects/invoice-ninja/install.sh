#!/usr/bin/env bash
# Invoice Ninja · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=billing.example.com ADMIN_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://invoiceninja.github.io/docs/self-host/self-host-installation
#   https://invoiceninja.github.io/docs/self-host/env-variables
#   https://github.com/invoiceninja/dockerfiles/blob/debian/README.md
#   https://github.com/invoiceninja/dockerfiles/blob/debian/debian/Dockerfile
#
# Four secrets are generated here, on this machine: the Laravel application key,
# the MySQL password, the MySQL root password and the password for the one
# account the first boot creates. All four go into /srv/invoice-ninja/.env with
# mode 600 and none of them is ever printed.
#
# DOMAIN_HOST is also APP_URL, which the first boot writes into the company
# record as the client-portal domain. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/invoice-ninja}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. billing.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address you want to sign in as"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 3072 ] || die "only ${avail_mb} MB of RAM available; MySQL plus php-fpm plus a headless Chrome wants 3072 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mysql/ and redis/ stay owned by root at mode 700: both images chown their own
# data directory on first start. The application's public/ and storage/ trees
# are named volumes, because the image ships its own public tree and refills it
# on every start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/nginx"
sudo install -d -m 700 "$APP_DIR/mysql" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cat > "$APP_DIR/nginx/invoice-ninja.conf" <<'NGINXCONF'
# Invoice Ninja · nginx for php-fpm, from https://laravel.com/docs/12.x/deployment#nginx

server {
	listen 80 default_server;
	root /var/www/html/public;
	index index.php;
	client_max_body_size 20M;

	location / {
		try_files $uri $uri/ /index.php?$query_string;
	}

	location ~ \.php$ {
		fastcgi_pass app:9000;
		fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
		include fastcgi_params;
	}
}
NGINXCONF

# --- 3. Generate the four secrets, on the server -----------------------------
#
# APP_KEY is base64: plus 32 random bytes in base64, the same shape
# `php artisan key:generate --show` prints. Read the account password later with
#   grep IN_PASSWORD /srv/invoice-ninja/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		APP_ENV=production
		APP_DEBUG=false
		REQUIRE_HTTPS=false
		TRUSTED_PROXIES=*
		IS_DOCKER=true
		FILESYSTEM_DISK=debian_docker
		CACHE_DRIVER=redis
		SESSION_DRIVER=redis
		QUEUE_CONNECTION=redis
		REDIS_HOST=redis
		DB_CONNECTION=mysql
		DB_HOST=mysql
		DB_DATABASE=ninja
		DB_USERNAME=ninja
		MAIL_MAILER=log
		IN_USER_EMAIL=${ADMIN_EMAIL}
		APP_KEY=base64:$(openssl rand -base64 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		DB_ROOT_PASSWORD=$(openssl rand -hex 32)
		IN_PASSWORD=$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-invoice-ninja"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of 8127, 3306, 6379, 9000 is one of them ---

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8127, 3306, 6379 and 9000 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first boot runs the Laravel migrations, seeds the reference data and then
# creates the account from IN_USER_EMAIL and IN_PASSWORD. Until that finishes
# nginx answers 502.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 app"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"status":"ok","message":"API is healthy"' \
	|| die "/health answered 200 without the documented body. Check: docker compose logs --tail 40 app"

home="$(curl -sS "https://${DOMAIN_HOST}/")"
printf '%s' "$home" | grep -q '<title>Invoice Ninja</title>' \
	|| die "the first screen is not Invoice Ninja. Check: docker compose logs --tail 40 nginx"
printf '%s' "$home" | grep -q 'Version: 5.13.30' \
	|| die "the running container does not report 5.13.30, so it is not the pinned digest"

# The account upstream's create-account command falls back to when it is called
# without --email and --password must not exist: this install passes both.
shipped="$(docker compose exec -T -u www-data app php artisan tinker \
	--execute='echo App\Models\User::where("email","admin@example.com")->count();' | tr -dc '0-9')"
[ "$shipped" = "0" ] || die "the published admin@example.com account exists. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mysql sh -c 'exec mysqldump -u ninja -p"$MYSQL_PASSWORD" --single-transaction --no-tablespaces ninja' \
	| gzip > "$APP_DIR/backups/invoice-ninja-db-${STAMP}.sql.gz"
docker compose exec -T app tar -czf - -C /var/www/html storage > "$APP_DIR/backups/invoice-ninja-storage-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/invoice-ninja-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env nginx -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/invoice-ninja-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/invoice-ninja-storage-${STAMP}.tar.gz" ] || die "the storage archive is empty"

cat <<-DONE

	Invoice Ninja is answering at https://${DOMAIN_HOST}

	  1. Sign in as ${ADMIN_EMAIL}. Your password is in $APP_DIR/.env, mode
	     600. Read it with
	       grep IN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and
	     there is no password-reset mail on this install.
	  2. No mail is delivered. MAIL_MAILER is log, which writes messages to
	     the application log and reports success, so emailing an invoice does
	     nothing until you add a provider under Settings, Email Settings.
	     Until then a client gets a PDF or a portal link you send yourself.
	  3. First backup written to $APP_DIR/backups: a database dump, a storage
	     archive and a config archive. They are on the same disk as the data,
	     which is not a backup. Copy all three off the box tonight, and keep
	     the config archive with the dump: APP_KEY lives in .env and it is
	     what decrypts the encrypted columns.

DONE
