#!/usr/bin/env bash
# Collabora Online (CODE) · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=office.example.com WOPI_HOST=https://cloud.example.com:443 ./install.sh
#
# Authored by caniselfhostit from the upstream sources:
#   https://github.com/CollaboraOnline/online.mirror/blob/main/docker/from-packages/Dockerfile
#   https://github.com/CollaboraOnline/online.mirror/blob/main/docker/README
#   https://github.com/CollaboraOnline/online.mirror/blob/main/wsd/COOLWSD.cpp
#   https://github.com/CollaboraOnline/online.mirror/blob/main/coolwsd.xml.in
#
# One secret is generated here, on this machine: the admin console password. It
# goes into /srv/collabora/.env with mode 600 and is never printed.
#
# This installs the editing engine only. It edits nothing on its own: another
# application, such as Nextcloud with the Collabora Online connector, hands it
# the documents. DOMAIN_HOST is the address that application will be pointed at,
# so it has to resolve for its server as well as for your browser. WOPI_HOST is
# the reverse: the address that application answers on, which this server will
# accept documents from. Leave WOPI_HOST unset and the alias group stays empty,
# which upstream treats as "all WOPI hosts will be denied" until you fill it in.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/collabora}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
WOPI_HOST="${WOPI_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. office.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; this install wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

case "${WOPI_HOST}" in
	""|http://*|https://*) : ;;
	*) die "WOPI_HOST must include a scheme and a port, e.g. https://cloud.example.com:443" ;;
esac

# --- 2. Lay the files out ----------------------------------------------------
#
# No data directory and no volume: coolwsd builds its chroot jails and its cache
# inside the container, which the upstream source calls a state-less container.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: this value is typed into a browser login box, and hex
# has no characters that invite a typo. Read it later with
#   sudo grep password /srv/collabora/.env
#
# The four names are lowercase because coolwsd reads them from the environment
# exactly as written: username and password become the admin console
# credentials, server_name is what upstream documents for a server behind a
# reverse proxy, and aliasgroup1 is the WOPI host allowlist.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		username=admin
		password=$(openssl rand -hex 24)
		server_name=${DOMAIN_HOST}:443
		aliasgroup1=${WOPI_HOST}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-collabora"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8165 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8165 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The image is about 470 MB compressed and the first start scans the fonts and
# dictionaries, so a few minutes of 502 here is normal rather than a fault.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 30); do
	body="$(curl -sS "https://${DOMAIN_HOST}/" || true)"
	[ "$body" = "OK" ] && break
	sleep 10
done
[ "${body:-}" = "OK" ] || die "the root probe answered '${body:-nothing}'. Check: docker compose logs --tail 40 collabora"

discovery="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/hosting/discovery" || true)"
[ "$discovery" = "200" ] || die "/hosting/discovery answered ${discovery}, not 200"

curl -sS "https://${DOMAIN_HOST}/hosting/discovery" | grep -q 'wopi-discovery' \
	|| die "/hosting/discovery did not contain the expected wopi-discovery element"

# The admin console must refuse a request that carries no credentials. Upstream
# answers 401 there when the console is enabled and the caller is not logged in;
# a 200 would mean the password never reached the container and the console is
# open to anyone who finds this hostname.
console="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/browser/dist/admin/admin.html" || true)"
[ "$console" = "401" ] || die "the admin console returned ${console}, not 401. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------
#
# Two files rebuild this service completely, and the Caddy site block is
# archived from /etc/caddy so the copy has the real hostname in it rather than
# the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/collabora-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/collabora-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

if [ -z "$WOPI_HOST" ]; then
	alias_note="No WOPI_HOST was given, so aliasgroup1 is empty and this server denies every application that asks it for a document. Put the address in $APP_DIR/.env, then run: docker compose up -d --force-recreate"
else
	alias_note="aliasgroup1 is ${WOPI_HOST}, so only that host may load documents through this server."
fi

cat <<-DONE

	Collabora Online is answering at https://${DOMAIN_HOST}/hosting/discovery

	  1. Nothing is editing a document yet. This is the editing engine, and
	     another application has to be pointed at it. In Nextcloud: install
	     the app named Collabora Online, open /settings/admin/richdocuments,
	     put https://${DOMAIN_HOST} in the Collabora Online server field, and
	     save.
	  2. ${alias_note}
	  3. The admin console is at
	       https://${DOMAIN_HOST}/browser/dist/admin/admin.html
	     Username admin. The password is in $APP_DIR/.env, mode 600. Read it
	     with
	       sudo grep password $APP_DIR/.env
	     and put it in your password manager. It was not printed here. An
	     unauthenticated request to that page was refused with 401, which is
	     the check that proves the password is in force.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the config, which is not a backup. Copy it somewhere else tonight.

DONE
