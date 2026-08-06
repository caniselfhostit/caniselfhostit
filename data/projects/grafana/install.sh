#!/usr/bin/env bash
# Grafana OSS · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=grafana.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://grafana.com/docs/grafana/latest/setup-grafana/installation/docker/
#   https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/
#   https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
#   https://github.com/grafana/grafana/blob/v13.1.2/docs/sources/developer-resources/api-reference/http-api/api-legacy/other.md
#
# Two values are generated here, on this machine, and neither is ever printed:
# the administrator password, because Grafana would otherwise create its admin
# account with the literal word admin as the password, and the encryption key
# that protects the data-source credentials Grafana stores in its database,
# because upstream ships a fixed one that anyone can read. Both land in
# /srv/grafana/.env with mode 600.
#
# DOMAIN_HOST becomes GF_SERVER_ROOT_URL, which Grafana builds share links and
# post-login redirects from, so it has to be the hostname you actually use.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/grafana}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. grafana.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; upstream documents 512 MB as the minimum"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image runs as uid 472 in group 0 and never chowns its own data directory:
# it warns that the path is not writable and then fails to build a database.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 472 -g 0 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two values, on the server -------------------------------
#
# Hex rather than base64 for both: this file is also read by Docker Compose, and
# base64 output can contain characters that make a shell interpolate. Read the
# password later with
#   grep GF_SECURITY_ADMIN_PASSWORD /srv/grafana/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		GF_SERVER_ROOT_URL=https://${DOMAIN_HOST}
		GF_SERVER_DOMAIN=${DOMAIN_HOST}
		GF_SECURITY_ADMIN_PASSWORD=$(openssl rand -hex 24)
		GF_SECURITY_SECRET_KEY=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-grafana"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8106 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8106 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 grafana"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"database": "ok"' \
	|| die "/api/health answered 200 without a healthy database. Check: docker compose logs --tail 40 grafana"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"version": "13.1.2"' \
	|| die "/api/health reports a version other than 13.1.2. The pinned image is not what is running."

# The account Grafana would have created for itself must not exist. Upstream
# documents basic auth on the HTTP API, and a rejected credential returns 401.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' -u admin:admin "https://${DOMAIN_HOST}/api/org" || true)"
[ "$unauth" = "401" ] || die "the shipped default credential returned ${unauth}, not 401. Stop: take this host off DNS and investigate."

# The login page is served, not a proxy error page.
curl -sSL "https://${DOMAIN_HOST}/login" | grep -q '<title>Grafana</title>' \
	|| die "https://${DOMAIN_HOST}/login did not serve the Grafana login page. Check the Caddy site block."

# --- 7. The first backup, before day one ends --------------------------------
#
# The archive carries the live Caddy site block from /etc/caddy, not the
# <DOMAIN> template in $APP_DIR.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/grafana-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/grafana-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Grafana is answering at https://${DOMAIN_HOST}

	  1. Sign in with the username admin. The password is in $APP_DIR/.env,
	     mode 600, and it was not printed here. Read it with
	       grep GF_SECURITY_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager now.
	  2. What you will see is an empty dashboard tool. That is correct.
	     Grafana holds no data of its own, so nothing appears on a panel
	     until you add a data source and something is producing numbers for
	     it to query. Installing that data source is a separate job.
	  3. First backup written to $APP_DIR/backups: the database, the two
	     generated values, the compose file and the live Caddy site block.
	     It is on the same disk as the data, which is not a backup. Copy it
	     somewhere else tonight, and keep .env with it: it holds the key
	     your data-source passwords are encrypted with.

DONE
