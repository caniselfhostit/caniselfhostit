#!/usr/bin/env bash
# Vaultwarden — the agent-free install.
#
# Everything the prompt tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=vault.example.com ACME_EMAIL=you@example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/dani-garcia/vaultwarden/wiki/Using-Docker-Compose
#   https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
#   https://github.com/dani-garcia/vaultwarden/wiki/Proxy-examples
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/vaultwarden}"
IMAGE="vaultwarden/server:1.37.1-alpine"

DOMAIN_HOST="${DOMAIN_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. vault.example.com"
[ -n "$ACME_EMAIL" ]  || die "set ACME_EMAIL — Let's Encrypt needs somewhere to warn you if renewal breaks"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

# The DNS record has to exist before Caddy asks for a certificate, or the
# request fails and you burn a Let's Encrypt rate-limit slot learning that.
resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

mkdir -p "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile"  "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Neither secret has ever existed anywhere else — not in the prompt, not in a
# chat window, not in this repository.
#
# Secret 1: the admin-page password. You keep this one.
# Secret 2: the Argon2 PHC hash of it, which is what the server stores. The
#           vaultwarden binary generates it; `hash` prompts twice, so it is fed
#           the same value twice on stdin.

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
	DOMAIN_HOST=${DOMAIN_HOST}
	ACME_EMAIL=${ACME_EMAIL}
	ADMIN_TOKEN=${ADMIN_TOKEN_ESCAPED}
ENVFILE

printf '%s\n' "$ADMIN_PASSPHRASE" > "$APP_DIR/admin-passphrase.txt"
chmod 600 "$APP_DIR/.env" "$APP_DIR/admin-passphrase.txt"
umask 022

# --- 4. Open exactly two ports ----------------------------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> opening 80/tcp and 443/tcp (and 443/udp for HTTP/3); everything else stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
fi

# --- 5. Start it -------------------------------------------------------------

cd "$APP_DIR"
docker compose pull
docker compose up -d

# --- 6. Prove it works before claiming it does -------------------------------

echo "==> waiting for https://${DOMAIN_HOST}/ (Caddy is getting a certificate)"
for attempt in $(seq 1 30); do
	code="$(curl -s -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "https://${DOMAIN_HOST}/ answered ${code:-nothing}. Check: docker compose logs caddy"

# --- 7. The first backup, before day one ends --------------------------------

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/vaultwarden}"
mkdir -p "$BACKUP_DIR"
docker compose stop vaultwarden
tar -czf "$BACKUP_DIR/vaultwarden-$(date +%Y%m%d-%H%M%S).tar.gz" -C "$APP_DIR" data .env
docker compose start vaultwarden

cat <<-DONE

	Vaultwarden is running at https://${DOMAIN_HOST}/

	  1. Open it and create your account. It is the only one — SIGNUPS_ALLOWED
	     is already "false" in compose.yml, so nobody else can register.
	  2. Point the official Bitwarden apps and browser extensions at
	     https://${DOMAIN_HOST} using their self-hosted server setting.
	  3. The admin page passphrase is in $APP_DIR/admin-passphrase.txt.
	     Put it in your new vault, then delete that file.
	  4. First backup written to $BACKUP_DIR. It is on the same machine, which
	     is not a backup. Copy it somewhere else tonight.

DONE
