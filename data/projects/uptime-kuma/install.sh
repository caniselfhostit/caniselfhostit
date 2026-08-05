#!/usr/bin/env bash
# Uptime Kuma — the agent-free install.
#
# Everything the prompt tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=status.example.com ACME_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/louislam/uptime-kuma/blob/master/compose.yaml
#   https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install
#   https://github.com/louislam/uptime-kuma/wiki/Reverse-Proxy
#
# There is nothing to generate here: your admin account is created in the browser
# on first visit, and it is the only credential this install has.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/uptime-kuma}"

DOMAIN_HOST="${DOMAIN_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. status.example.com"
[ -n "$ACME_EMAIL" ]  || die "set ACME_EMAIL — Let's Encrypt needs somewhere to warn you if renewal breaks"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# ./data must be on local disk. Uptime Kuma keeps its history in SQLite and needs
# real POSIX file locks; a network mount here corrupts the database silently.

mkdir -p "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile"  "$APP_DIR/Caddyfile"

umask 077
cat > "$APP_DIR/.env" <<-ENVFILE
	DOMAIN_HOST=${DOMAIN_HOST}
	ACME_EMAIL=${ACME_EMAIL}
ENVFILE
chmod 600 "$APP_DIR/.env"
umask 022

# --- 3. Open exactly two ports ----------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> opening 80/tcp and 443/tcp (and 443/udp for HTTP/3); everything else stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
fi

# --- 4. Start it -------------------------------------------------------------

cd "$APP_DIR"
docker compose pull
docker compose up -d

# --- 5. Prove it works before claiming it does -------------------------------

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for attempt in $(seq 1 30); do
	code="$(curl -s -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs caddy"

# --- 6. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/uptime-kuma}"
mkdir -p "$BACKUP_DIR"
docker compose stop uptime-kuma
tar -czf "$BACKUP_DIR/uptime-kuma-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$APP_DIR" data
docker compose start uptime-kuma

cat <<-DONE

	Uptime Kuma is running at https://${DOMAIN_HOST}/

	  1. Open it now and create the admin account. Until you do, the setup screen
	     is open to whoever finds the hostname first.
	  2. Add your first monitor, then deliberately break it (point one at a
	     hostname that does not exist) to prove your notifications actually
	     arrive. An untested alert channel is not an alert channel.
	  3. Point one free external check at ${DOMAIN_HOST} itself. This server
	     cannot tell you it is down.
	  4. First backup written to $BACKUP_DIR. It is on the same machine, which
	     is not a backup. Copy it somewhere else tonight.

DONE
