#!/usr/bin/env bash
# ONLYOFFICE Docs · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=docs.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://helpcenter.onlyoffice.com/docs/installation/docs-community-install-docker.aspx
#   https://helpcenter.onlyoffice.com/docs/installation/docs-community-sys-reqs-docker.aspx
#   https://github.com/ONLYOFFICE/Docker-DocumentServer/blob/master/README.md
#   https://api.onlyoffice.com/docs/docs-api/additional-api/conversion-api/error-codes/
#
# One secret is generated here, on this machine: the token secret every request
# between this server and the application that uses it is signed with. It goes
# into /srv/onlyoffice/.env with mode 600 and is never printed.
#
# This installs the editing engine only. It edits nothing on its own: another
# application, such as Nextcloud with the ONLYOFFICE connector, hands it the
# documents. DOMAIN_HOST is the address that application will be pointed at, so
# it has to resolve for its server as well as for your browser.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/onlyoffice}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. docs.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; upstream asks for 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 40 ] || die "only ${avail_gb} GB free on /srv; upstream asks for 40 GB"

swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"
[ "$swap_mb" -ge 4096 ] || echo "==> warning: ${swap_mb} MB of swap; upstream asks for 4096 MB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data, lib and log are chowned by the container to the account it runs its own
# services as, on every start. Do not chown them again afterwards.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/data" "$APP_DIR/lib" "$APP_DIR/logs"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: this value is pasted into a web form in another
# application, and hex survives that trip without escaping. Read it later with
#   sudo grep JWT_SECRET /srv/onlyoffice/.env
#
# Token validation is on by default upstream, and with no secret set the
# entrypoint invents a random one at every container start, which silently
# breaks every integration on restart. That is what this file prevents.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		JWT_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-onlyoffice"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8157 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8157 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The image is over a gigabyte compressed and the first start regenerates the
# font list, so several minutes of 502 here is normal rather than a fault.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthcheck"
for _ in $(seq 1 40); do
	body="$(curl -sS "https://${DOMAIN_HOST}/healthcheck" || true)"
	[ "$body" = "true" ] && break
	sleep 15
done
[ "${body:-}" = "true" ] || die "/healthcheck answered '${body:-nothing}'. Check: docker compose logs --tail 40 documentserver"

welcome="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/welcome/" || true)"
[ "$welcome" = "200" ] || die "the welcome page answered ${welcome}, not 200"

curl -sS "https://${DOMAIN_HOST}/welcome/" | grep -q 'ONLYOFFICE Docs Community Edition installed' \
	|| die "the welcome page did not contain the expected first-screen string"

# The editor must refuse an unsigned conversion request. Upstream documents -8
# as the code for an invalid token; anything else means the secret is not in
# force and this server would convert documents for anyone who finds it.
convert="$(curl -sS -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' \
	-d '{"async":false,"filetype":"docx","key":"selfhostcheck","outputtype":"pdf","url":"https://example.com/none.docx"}' \
	"https://${DOMAIN_HOST}/converter" || true)"
case "$convert" in
	*'"error":-8'*) : ;;
	*) die "an unsigned conversion request returned ${convert}, not error -8. Stop and investigate." ;;
esac

# --- 7. The first backup, before day one ends --------------------------------
#
# lib and logs are left out: a cache of open documents and a pile of logs are
# not worth restoring. The member that matters is .env.

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/onlyoffice-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/onlyoffice-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	ONLYOFFICE Docs is answering at https://${DOMAIN_HOST}/welcome/

	  1. Nothing is editing a document yet. This is the editing engine, and
	     another application has to be pointed at it. In Nextcloud: install
	     the app named ONLYOFFICE, open /settings/admin/onlyoffice, put
	     https://${DOMAIN_HOST}/ in the Document Editing Service address
	     field, and paste the secret into the Secret key field.
	  2. The secret is in $APP_DIR/.env, mode 600. Read it with
	       sudo grep JWT_SECRET $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	  3. An unsigned conversion request was refused with error -8, which is
	     upstream's code for an invalid token. That is the check that proves
	     the secret is in force.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
