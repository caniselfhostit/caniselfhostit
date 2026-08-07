#!/usr/bin/env bash
# Vane · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=ask.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/ItzCrazyKns/Vane/blob/v1.12.2/README.md
#   https://github.com/ItzCrazyKns/Vane/blob/v1.12.2/docs/installation/UPDATING.md
#   https://docs.searxng.org/admin/installation-docker.html
#   https://docs.searxng.org/admin/settings/settings_server.html
#   https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# The project was called Perplexica until it was renamed Vane. The repository,
# the images and the docs moved with the name; 1.12.2 exists only under the new
# one.
#
# Two secrets are generated here, on this machine: the SearXNG session key and
# the password on the Caddy login box in front of the app. Neither is ever
# printed. Vane ships no sign-in of its own, so that login box is the only thing
# between the internet and a setup screen holding your provider API key.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/perplexica}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. ask.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Vane plus SearXNG wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# basic_auth is what Caddy 2.8 renamed basicauth to, and the site block uses it.
caddy_line="$(caddy version | head -1)"
caddy_major="$(printf '%s' "$caddy_line" | sed -E 's/^v?([0-9]+)\.([0-9]+).*/\1/')"
caddy_minor="$(printf '%s' "$caddy_line" | sed -E 's/^v?([0-9]+)\.([0-9]+).*/\2/')"
if [ "$caddy_major" -lt 2 ] || { [ "$caddy_major" -eq 2 ] && [ "$caddy_minor" -lt 8 ]; }; then
	die "caddy 2.8 or newer is required for basic_auth; this box has ${caddy_line}"
fi

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/data" "$APP_DIR/uploads"
sudo install -d -m 755 "$APP_DIR/searxng"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# SearXNG serves html only until told otherwise, and Vane asks for json.
sudo tee "$APP_DIR/searxng/settings.yml" >/dev/null <<'SETTINGS'
# SearXNG · the search backend here. Authored by caniselfhostit from
# https://docs.searxng.org/admin/settings/ and Vane's own install notes.
# No secret_key here: SEARXNG_SECRET in compose.yml overwrites it with the
# value install.sh generated. Nothing in this file is confidential.
use_default_settings: true

search:
  # SearXNG answers 403 to a format it was not told to serve, and ships html
  # only, so without json every Vane search fails.
  formats:
    - html
    - json

server:
  # The shipped default, stated so an upstream change cannot turn it on.
  limiter: false

engines:
  - name: wolframalpha
    disabled: false
SETTINGS
sudo chmod 644 "$APP_DIR/searxng/settings.yml"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: one is typed into a browser dialog and the
# other is read by a container. Read the browser one later with
#   sudo cat /srv/perplexica/browser-login

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SEARXNG_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi
if [ ! -f "$APP_DIR/browser-login" ]; then
	umask 077
	openssl rand -hex 24 > "$APP_DIR/browser-login"
	chmod 600 "$APP_DIR/browser-login"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. The login box, then the Caddy site block, on the host ----------------
#
# Vane has no sign-in of its own, so Caddy is the sign-in. The hash is built
# from a file rather than an argument so the value never reaches the process
# list.

umask 077
caddy hash-password < "$APP_DIR/browser-login" > "$APP_DIR/vane-auth.hash"
printf 'basic_auth {\n\tvane %s\n}\n' "$(cat "$APP_DIR/vane-auth.hash")" > "$APP_DIR/vane-auth.conf"
umask 022
sudo install -m 640 -o root -g caddy "$APP_DIR/vane-auth.conf" /etc/caddy/vane-auth.conf
rm -f "$APP_DIR/vane-auth.hash" "$APP_DIR/vane-auth.conf"
[ "$(sudo grep -c basic_auth /etc/caddy/vane-auth.conf)" = "1" ] || die "/etc/caddy/vane-auth.conf did not get its basic_auth block"

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-perplexica"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8148 nor 8080 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8148 and 8080 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for http://127.0.0.1:8148/"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8148/" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "the app answered ${code:-nothing}. Check: docker compose logs --tail 40 vane"

curl -sS "http://127.0.0.1:8148/api/config" | grep -q '"searxngURL":"http://searxng:8080"' \
	|| die "/api/config does not point at the searxng container. Check: docker compose logs --tail 40 vane"

curl -sS "http://127.0.0.1:8148/" | grep -q 'Welcome to' \
	|| die "the first screen is not the setup wizard. Check: docker compose logs --tail 40 vane"

# The search backend has to answer JSON, or every query fails later.
docker compose exec -T searxng wget -qO- 'http://127.0.0.1:8080/search?q=self+hosting&format=json' | grep -q '"query"' \
	|| die "searxng did not answer json. Check that $APP_DIR/searxng/settings.yml is mounted."

# Caddy must refuse an unauthenticated request. An open Vane on a public
# hostname is a stranger spending your money on your provider key.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated request returned ${unauth}, not 401. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop vane
sudo tar -czf "$APP_DIR/backups/perplexica-${STAMP}.tar.gz" -C "$APP_DIR" data uploads searxng .env browser-login compose.yml -C /etc/caddy Caddyfile
docker compose start vane
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/perplexica-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Vane is answering at https://${DOMAIN_HOST}

	  1. Sign in with the username  vane  and the password in
	     $APP_DIR/browser-login, mode 600. Read it with
	       sudo cat $APP_DIR/browser-login
	     and put it in your password manager. It was not printed here.
	     Vane has no sign-in of its own; that box is the whole login.
	  2. The first screen is a setup wizard. It asks for a model provider.
	     Paste your own API key from Anthropic, OpenAI or Google into it: the
	     answers are metered per token and billed to that account, and this
	     install holds no credential of its own.
	  3. Searches go through the SearXNG container, which asks public engines
	     and gets refused by some of them from a datacenter address. Thin
	     answers usually mean a suspended engine, not a broken install:
	       docker compose exec -T searxng wget -qO- 'http://127.0.0.1:8080/stats/errors'
	  4. First backup written to $APP_DIR/backups. It was taken before the
	     wizard, so your key is not in it yet: take another once setup is
	     done, and treat every backup after that like a password file,
	     because data/config.json holds the key. Either way it sits on the
	     same disk as the data, which is not a backup. Copy it somewhere
	     else tonight.

DONE
