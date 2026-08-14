#!/usr/bin/env bash
# OpnForm · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=forms.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.opnform.com/deployment/docker
#   https://docs.opnform.com/configuration/environment-variables
#   https://docs.opnform.com/deployment/self-hosted-license
#   https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker-compose.yml
#   https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker/nginx.conf
#
# Five secrets are generated here, on this machine: the Laravel application
# key, the JWT signing key, the shared secret between the Nuxt server and the
# API, the PostgreSQL password and the Redis password. All five go into
# /srv/opnform/.env with mode 600 and none of them is ever printed.
#
# DOMAIN_HOST becomes APP_URL, FRONT_URL and NUXT_PUBLIC_APP_URL at once, and
# every form link is that hostname plus /forms/ and a slug. Choose it once:
# changing it later breaks links you have already sent out.
#
# This script leaves the setup page OPEN, because only a human with a browser
# can create the first account, and whoever reaches the hostname first becomes
# the owner of this instance. The closing summary gives you the three commands
# that prove it closed. Do it the same hour.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/opnform}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. forms.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; seven containers with three PHP processes want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')" || resolved=""
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The ingress config is written before anything starts: Docker makes a
# directory where a missing bind-mount file should be, and nginx then refuses
# a config that is a folder.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/nginx"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cat > "$APP_DIR/nginx/default.conf" <<'NGINXCONF'
# OpnForm · the ingress, authored by caniselfhostit from
# https://github.com/OpnForm/OpnForm/blob/v2.3.0/docker/nginx.conf
# The map strips /api before PHP sees it, since Laravel's routes are at the
# root; `root` is a path inside the api container and only builds
# SCRIPT_FILENAME, so nothing static is served from this one.

map $request_uri $api_uri {
    ~^/api(/.*$) $1;
    default $request_uri;
}

server {
    listen 80;
    root /usr/share/nginx/html/public;
    client_max_body_size 50m;

    location / {
        proxy_http_version 1.1;
        proxy_pass http://client:3000;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
    }

    location ~/(api|open|local\/temp|forms\/assets)/ {
        try_files $uri /index.php$is_args$args;
    }

    location ~ \.php$ {
        fastcgi_pass api:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/index.php;
        fastcgi_param REQUEST_URI $api_uri;
        fastcgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
    }
}
NGINXCONF

# --- 3. Generate the five secrets, on the server -----------------------------
#
# APP_KEY has a shape: base64: followed by 32 random bytes in base64, which is
# what `php artisan key:generate --show` produces. The other four are hex,
# because two of them travel inside connection strings. Read them later with
#   sudo grep -E 'APP_KEY|JWT_SECRET|FRONT_API_SECRET' /srv/opnform/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		FRONT_URL=https://${DOMAIN_HOST}
		APP_KEY=base64:$(openssl rand -base64 32)
		JWT_SECRET=$(openssl rand -hex 32)
		FRONT_API_SECRET=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-opnform"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8186, 5432, 6379, 9000 and 3000 are none of them -

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; everything else stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# First boot is slow on purpose: the api container waits for PostgreSQL, runs
# every migration and caches its configuration, and the other four wait for it
# to report healthy.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/healthcheck"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/healthcheck" 2>/dev/null)" || code="000"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/healthcheck answered ${code:-nothing}. Check: docker compose logs --tail 60 api ingress"

# The health body names both dependencies, which is the only way to tell a
# container that never started from one that reached neither database.
curl -sS "https://${DOMAIN_HOST}/api/healthcheck" | grep -q '"dependencies":{"database":true,"redis":true}' \
	|| die "/api/healthcheck answered 200 without both dependencies up. Check: docker compose logs --tail 60 api"

# Nobody has claimed this instance yet, which is exactly why the summary below
# is urgent rather than informational.
curl -sS "https://${DOMAIN_HOST}/api/content/feature-flags" | grep -q '"setup_required":true' \
	|| die "setup_required is not true: an account already exists on this instance, or the client is not reachable"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db pg_dump -U opnform -d opnform | gzip > "$APP_DIR/backups/opnform-db-${STAMP}.sql.gz"
docker compose exec -T api tar -czf - -C /usr/share/nginx/html storage > "$APP_DIR/backups/opnform-storage-${STAMP}.tar.gz"
sudo tar -czf "$APP_DIR/backups/opnform-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env nginx -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/opnform-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/opnform-storage-${STAMP}.tar.gz" ] || die "the storage archive is empty"

cat <<-DONE

	OpnForm is answering at https://${DOMAIN_HOST}

	  1. The setup page is OPEN right now, to anyone who finds the hostname,
	     and whoever fills it in owns this instance. There is no second
	     chance: OpnForm refuses public registration permanently once one
	     account exists. Open https://${DOMAIN_HOST} in a browser, create
	     your admin account, then check that the door shut:

	       curl -sS https://${DOMAIN_HOST}/api/content/feature-flags | grep -o '"setup_required":false'
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/setup
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/register

	     Those must print "setup_required":false, then 404, then 302. Do this
	     the same hour, not tomorrow.
	  2. Your five secrets are in $APP_DIR/.env, mode 600. None was printed
	     here. Read them yourself with
	       sudo grep -E 'APP_KEY|JWT_SECRET' $APP_DIR/.env
	  3. First backup written to $APP_DIR/backups: a PostgreSQL dump, a
	     storage archive holding respondent attachments, and a config archive
	     carrying .env and the live Caddy config. They are on the same disk as
	     the data, which is not a backup. Copy them off tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/opnform/
	  4. No mail server is configured, so password reset and response
	     notifications do not work. That one account is your whole way back in.
	  5. A licence-free self-hosted instance is capped at two users in total.
	     Everyone after you joins by invitation from inside the workspace.

DONE
