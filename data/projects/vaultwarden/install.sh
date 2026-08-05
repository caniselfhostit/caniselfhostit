#!/usr/bin/env bash
# Vaultwarden · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=vault.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose
#   https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
#   https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples
#   https://github.com/dani-garcia/vaultwarden/wiki/Enabling-WebSocket-notifications
#
# Two secrets are generated here, on this machine: the admin-page passphrase and
# the Argon2 PHC hash of it that the server stores. Neither is printed.
#
# TLS is not this script's job. The Caddy that Prompt Zero installed under systemd
# terminates it and reaches the container on 127.0.0.1:8222, so this script
# appends one site block to /etc/caddy/Caddyfile and opens no application port.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/vaultwarden}"
IMAGE="vaultwarden/server:1.37.1-alpine@sha256:b094afed4ed5ea353821c6efcedca446f30c6654ba2bc441db6089b0c2b94ac8"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. vault.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

# The DNS record has to exist before Caddy asks for a certificate, or the request
# fails and you burn a Let's Encrypt rate-limit slot learning that.
resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/data" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Neither secret has ever existed anywhere else: not in the prompt, not in a chat
# window, not in this repository.
#
# Secret 1: the admin-page passphrase. You keep this one.
# Secret 2: the Argon2 PHC hash of it, which is what the server stores. The
#           vaultwarden binary generates it; `hash` prompts twice, so it is fed
#           the same value twice on stdin.

if [ ! -f "$APP_DIR/.env" ]; then
	ADMIN_PASSPHRASE="$(openssl rand -base64 33)"

	hash_passphrase() {
		printf '%s\n%s\n' "$1" "$1" \
			| docker run --rm -i "$IMAGE" /vaultwarden hash --preset owasp \
			| grep -o '\$argon2[^ ]*' \
			| tail -n 1
	}

	ADMIN_TOKEN="$(hash_passphrase "$ADMIN_PASSPHRASE")"
	[ -n "$ADMIN_TOKEN" ] || die "could not generate the admin token hash"

	# docker compose expands "$" inside .env values, and an Argon2 PHC string is
	# full of them. Escaping every "$" as "$$" is the single most common thing
	# people get wrong here.
	ADMIN_TOKEN_ESCAPED="$(printf '%s' "$ADMIN_TOKEN" | sed 's/[$]/$$/g')"

	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DOMAIN=https://${DOMAIN_HOST}
		ADMIN_TOKEN=${ADMIN_TOKEN_ESCAPED}
	ENVFILE
	printf '%s\n' "$ADMIN_PASSPHRASE" > "$APP_DIR/admin-passphrase.txt"
	chmod 600 "$APP_DIR/.env" "$APP_DIR/admin-passphrase.txt"
	umask 022
	unset ADMIN_PASSPHRASE ADMIN_TOKEN ADMIN_TOKEN_ESCAPED
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-vaultwarden"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8222 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8222 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

# --- 7. Prove it works before claiming it does -------------------------------
#
# /alive opens the database to answer, so a 200 means both the container and the
# vault file are good. A green `docker ps` proves neither.

echo "==> waiting for https://${DOMAIN_HOST}/alive (Caddy is getting a certificate)"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/alive" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/alive answered ${code:-nothing}. Check: docker compose logs vaultwarden, and sudo journalctl -u caddy -n 30"

# --- 8. The first backup, before day one ends --------------------------------
#
# Stopped, then copied. A SQLite file captured mid-write is not a backup.

docker compose stop
tar -C "$APP_DIR" -czf "$APP_DIR/backups/vaultwarden-$(date +%Y%m%d-%H%M%S).tar.gz" data .env
docker compose start
ls -lh "$APP_DIR/backups/"

cat <<-DONE

	Vaultwarden is running at https://${DOMAIN_HOST}/

	  1. Registration is CLOSED, which is the state this install ships in, so
	     open it only for as long as it takes you to register:
	       cd $APP_DIR
	       sed -i 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' compose.yml
	       docker compose up -d --force-recreate vaultwarden
	  2. Open https://${DOMAIN_HOST}/ and create your account. The first screen
	     shows a "Log in" heading and a "Create account" link.
	  3. Close it again, then reload the page and confirm the "Create account"
	     link is gone. That check is the one with security meaning:
	       sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' compose.yml
	       docker compose up -d --force-recreate vaultwarden
	  4. Point the official Bitwarden apps and browser extensions at
	     https://${DOMAIN_HOST} using their self-hosted server setting.
	  5. The admin page passphrase is in $APP_DIR/admin-passphrase.txt. Put it in
	     your new vault, then delete that file.
	  6. First backup written to $APP_DIR/backups. It is on the same disk as the
	     data, which is not a backup. Copy it off the box tonight with
	     scp vps:$APP_DIR/backups/*.tar.gz ~/backups/vaultwarden/

DONE
