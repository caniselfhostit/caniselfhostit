#!/usr/bin/env bash
# Zulip · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=chat.example.com ADMIN_EMAIL=you@example.com \
#     SMTP_HOST=smtp.example.com SMTP_USER=noreply@example.com ./install.sh
#
# SMTP_PASSWORD is read from the terminal if it is not already set, so the
# relay password never has to appear in your shell history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://zulip.readthedocs.io/projects/docker/en/latest/how-to/compose-getting-started.html
#   https://zulip.readthedocs.io/projects/docker/en/latest/reference/environment-vars.html
#   https://zulip.readthedocs.io/projects/docker/en/latest/how-to/compose-ssl.html
#   https://github.com/zulip/docker-zulip/blob/12.2-0/entrypoint.sh
#
# Five secrets are generated here, on this machine: the PostgreSQL,
# memcached, RabbitMQ and Redis passwords the containers authenticate to
# each other with, and the Django key that seals every session. They go into
# /srv/zulip/.env with mode 600 and are never printed.
#
# This script cannot create the first organization, because only a human
# with a browser can. It generates the single-use link and leaves it in a
# mode-600 file for you to read; the closing summary says where.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/zulip}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USE_TLS="${SMTP_USE_TLS:-True}"
SMTP_USE_SSL="${SMTP_USE_SSL:-False}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. chat.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address Zulip should send error reports to"
[ -n "$SMTP_HOST" ] || die "set SMTP_HOST to your transactional relay. Zulip drops mail silently without one."
[ -n "$SMTP_USER" ] || die "set SMTP_USER to the username your relay expects"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; five containers plus Zulip want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')" || resolved=""
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

if [ -z "${SMTP_PASSWORD:-}" ]; then
	printf 'Relay password for %s (not echoed): ' "$SMTP_USER" >&2
	read -rs SMTP_PASSWORD
	printf '\n' >&2
fi
[ -n "$SMTP_PASSWORD" ] || die "the relay password is empty"

# --- 2. Lay the files out ----------------------------------------------------
#
# The Zulip container runs as root and creates uploads/ and
# zulip-secrets.conf under data/ itself; PostgreSQL chowns its own cluster.
# RabbitMQ and Redis use named volumes and need nothing here.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/data" "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the five secrets, on the server -----------------------------
#
# Hex throughout: each value is read out of .env by Compose and rewritten
# into a config file inside the container, and a $ or a quote in the middle
# of that trip is an outage nobody diagnoses quickly. Read them later with
#   grep ZULIP_ /srv/zulip/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DOMAIN=${DOMAIN_HOST}
		ZULIP_ADMIN_EMAIL=${ADMIN_EMAIL}
		ZULIP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
		ZULIP_MEMCACHED_PASSWORD=$(openssl rand -hex 32)
		ZULIP_RABBITMQ_PASSWORD=$(openssl rand -hex 32)
		ZULIP_REDIS_PASSWORD=$(openssl rand -hex 32)
		ZULIP_SECRET_KEY=$(openssl rand -hex 32)
		MEMCACHED_SASL_DB=/home/memcache/memcached-sasl-db
		ZULIP_EMAIL_HOST=${SMTP_HOST}
		ZULIP_EMAIL_USER=${SMTP_USER}
		ZULIP_EMAIL_PASSWORD=${SMTP_PASSWORD}
		ZULIP_EMAIL_PORT=${SMTP_PORT}
		ZULIP_EMAIL_USE_TLS=${SMTP_USE_TLS}
		ZULIP_EMAIL_USE_SSL=${SMTP_USE_SSL}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-zulip"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of the five service ports is one of them ----

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8192, 5432, 11211, 5672, 6379 and 25 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Boot it, upstream's way ----------------------------------------------
#
# app:init validates the configuration and migrates the database in a
# one-shot container that fails loudly, before the server that fails slowly.

docker compose pull
if ! docker compose run --rm zulip app:init | tee /tmp/zulip-init.log; then
	die "app:init exited non-zero. Read /tmp/zulip-init.log before starting the server."
fi
grep -q '=== End Initial Configuration Phase ===' /tmp/zulip-init.log \
	|| die "app:init did not reach the end of the configuration phase. Read /tmp/zulip-init.log."
rm -f /tmp/zulip-init.log

docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health (first boot takes minutes)"
code=""
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || echo "000")"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "$code" = "200" ] || die "/health answered ${code}. Check: docker compose logs --tail 60 zulip"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"result":"success"' \
	|| die "/health answered 200 without a success body. Check: docker compose logs --tail 60 zulip"

# The public organization creation page must already be refusing strangers:
# Zulip ships with OPEN_REALM_CREATION off, and nothing here turns it on.
curl -sS "https://${DOMAIN_HOST}/new/" | grep -q 'Organization creation link required' \
	|| die "the organization creation page is not refusing anonymous callers. Stop and investigate."

# --- 7. The one-time link only a human can use -------------------------------

umask 077
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py generate_realm_creation_link \
	| grep -o "https://[^[:space:]]*/new/[A-Za-z0-9]*" > "$APP_DIR/realm-link.txt"
umask 022
[ "$(wc -l < "$APP_DIR/realm-link.txt")" -eq 1 ] \
	|| die "no organization creation link was produced. Check: docker compose logs --tail 40 zulip"

# --- 8. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T zulip /sbin/entrypoint.sh app:backup
sudo tar -czf "$APP_DIR/backups/zulip-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/zulip-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Zulip is answering at https://${DOMAIN_HOST}/health

	  1. Read your one-time organization creation link:
	       cat ${APP_DIR}/realm-link.txt
	     Open it, fill in the page headed "Create a new Zulip organization",
	     and save that password in your password manager before you submit.
	     The link is single-use and expires in seven days. Delete the file
	     once you are in:  rm -f ${APP_DIR}/realm-link.txt
	  2. Then prove the front door is still shut. This has to print 1:
	       curl -sS https://${DOMAIN_HOST}/new/ | grep -c 'Organization creation link required'
	  3. Then prove mail leaves the box:
	       docker compose exec -T -u zulip zulip \\
	         /home/zulip/deployments/current/manage.py send_test_email ${ADMIN_EMAIL}
	     If that raises, the relay details in ${APP_DIR}/.env are wrong.
	  4. Your five generated secrets are in ${APP_DIR}/.env, mode 600. Read
	     them with:  grep ZULIP_ ${APP_DIR}/.env
	  5. First backup written to ${APP_DIR}/backups. It predates your
	     organization, so take another once you are in. It sits on the same
	     disk as the data, which is not a backup: copy it off tonight.

DONE
