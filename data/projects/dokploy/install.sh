#!/usr/bin/env bash
# Dokploy · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=deploy.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.dokploy.com/docs/core/installation
#   https://docs.dokploy.com/docs/core/manual-installation
#   https://docs.dokploy.com/docs/core/architecture
#   https://docs.dokploy.com/docs/core/applications
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# the key the panel signs every session with. Both go into /srv/dokploy/.env
# with mode 600 and neither is ever printed.
#
# Read this before running it. Dokploy drives this host's Docker daemon through
# a mounted socket and puts the machine into Swarm mode to do it, so whoever
# holds the panel password holds this server. This script starts no Traefik:
# Caddy keeps 80 and 443, and applications you deploy later get a host port and
# a Caddy site block of their own.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/dokploy}"
PANEL_DIR="${PANEL_DIR:-/etc/dokploy}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. deploy.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; the panel plus PostgreSQL plus builds want 2048 MB"
avail_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 30 ] || die "only ${avail_gb} GB free on /; this install wants 30 GB because builds run here"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out, and put Docker into Swarm mode --------------------
#
# /srv/dokploy is ours. /etc/dokploy is the panel's, and the path cannot move:
# the panel writes it inside the container and hands the same string to the
# Docker daemon out here. Mode 750 root-owned rather than upstream's 777,
# because the container runs as root and needs nothing wider.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
sudo install -d -m 750 "$PANEL_DIR"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# One node, nothing will ever join it, so the cluster port advertises on
# loopback rather than a public interface.
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active \
	|| docker swarm init --advertise-addr 127.0.0.1
docker network inspect dokploy-network >/dev/null 2>&1 \
	|| docker network create --driver overlay --attachable dokploy-network
docker info --format 'swarm={{.Swarm.LocalNodeState}}' | grep -q 'swarm=active' \
	|| die "Docker is not in Swarm mode, and everything this panel deploys is a Swarm service"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex for both: one travels inside a PostgreSQL connection string. Read them
# later with
#   sudo grep -E 'DB_PASSWORD|AUTH_SECRET' /srv/dokploy/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DB_PASSWORD=$(openssl rand -hex 32)
		AUTH_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-dokploy"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of the other five --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8144, 5432 and the Swarm ports stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The panel waits for PostgreSQL, runs its own migrations, then serves.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 dokploy"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"ok":true' \
	|| die "/api/health answered 200 without ok:true. Check: docker compose logs --tail 40 dokploy"

# An instance with no account sends everyone to /register, and that page is the
# proof the panel reached you through Caddy rather than a proxy error.
landing="$(curl -sSL -o /dev/null -w '%{url_effective}' "https://${DOMAIN_HOST}/" || true)"
[ "$landing" = "https://${DOMAIN_HOST}/register" ] \
	|| die "https://${DOMAIN_HOST}/ landed on ${landing:-nothing}, not /register. Stop and investigate."

curl -sSL "https://${DOMAIN_HOST}/register" | grep -q 'Setup the server' \
	|| die "the first screen did not carry 'Setup the server'. Check: docker compose logs --tail 40 dokploy"

# No proxy of the panel's own should exist. One that does wants 80 and 443.
[ -z "$(docker ps -a --filter name=dokploy-traefik --format '{{.Names}}')" ] \
	|| die "a dokploy-traefik container exists and wants ports 80 and 443, which Caddy holds. Remove it."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U dokploy -d dokploy | gzip > "$APP_DIR/backups/dokploy-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/dokploy-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc dokploy -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/dokploy-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Dokploy is answering at https://${DOMAIN_HOST}/api/health

	  1. Open https://${DOMAIN_HOST} and create your account. The first screen
	     reads "Setup the server". That account is the only one this instance
	     will ever offer to make, and no mail server here can reset it, so put
	     the password in your password manager first.
	  2. Then open Settings, Web Server, and set the panel's domain to
	     ${DOMAIN_HOST} with HTTPS enabled, so the panel knows its own address.
	  3. No Traefik was started. Caddy keeps 80 and 443, so the Domains tab on
	     an application will not issue anything. Give the application a
	     published port instead, then add a Caddy site block for its hostname
	     pointing at 127.0.0.1 and that port, the way $APP_DIR/Caddyfile does.
	  4. Your two secrets are in $APP_DIR/.env, mode 600, and were not printed:
	       sudo grep -E 'DB_PASSWORD|AUTH_SECRET' $APP_DIR/.env
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive that includes /etc/dokploy. They are on the same disk as the
	     data, which is not a backup. Copy them somewhere else tonight.

DONE
