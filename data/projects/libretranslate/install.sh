#!/usr/bin/env bash
# LibreTranslate · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=translate.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.libretranslate.com/guides/installation/
#   https://docs.libretranslate.com/
#   https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/libretranslate/default_values.py
#   https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/docker/Dockerfile
#   https://github.com/LibreTranslate/LibreTranslate/blob/v1.9.6/scripts/entrypoint.sh
#
# One secret is generated here, on this machine: the API key every translation
# request has to carry. It goes into /srv/libretranslate/api-key with mode 600,
# is registered with the service over standard input so it never reaches a
# process list, and is never printed.
#
# The first start downloads about 2.1 GB of translation models before anything
# answers. The wait loop below allows fifteen minutes for that.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/libretranslate}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
KEY_FILE="${APP_DIR}/api-key"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. translate.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; the translation models want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# db belongs to uid 1032 because the image creates its own account with that id
# and runs as it. There is no data directory: nothing translated is stored.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1032 -g 1032 "$APP_DIR/db"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"

# --- 3. Generate the API key, on the server ----------------------------------
#
# Hex rather than base64: this value gets typed into settings boxes on other
# machines. The trailing newline is stripped so the file can be handed to curl
# and to the container verbatim. Read it later with
#   cat /srv/libretranslate/api-key

if [ ! -f "$KEY_FILE" ]; then
	umask 077
	openssl rand -hex 24 | tr -d '\n' > "$KEY_FILE"
	chmod 600 "$KEY_FILE"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-libretranslate"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$(dirname "$0")/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8154 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8154 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start downloads the 22 model packages named by LT_LOAD_ONLY before
# the service answers anything. Watch it with:
#   docker compose logs -f libretranslate

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health (models download on the first start)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing} after 15 minutes. Check: docker compose logs --tail 40 libretranslate"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"status": *"ok"' \
	|| die "/health answered 200 without status ok. Check: docker compose logs --tail 40 libretranslate"

curl -sS "https://${DOMAIN_HOST}/languages" | grep -q '"code": *"es"' \
	|| die "/languages does not list Spanish, so the models did not install. Check: docker compose logs --tail 40 libretranslate"

# The key travels on standard input, so it is in no command line and no process
# list. 120 is this key's request limit per minute. The redirect discards the
# copy the tool would otherwise echo.
docker compose exec -T libretranslate sh -c 'ltmanage keys add 120 --key "$(cat)"' < "$KEY_FILE" > /dev/null

# The service must refuse a call that carries no key. Upstream answers 400 with
# a message telling the caller to ask the operator for one.
noauth="$(curl -sS -o /dev/null -w '%{http_code}' --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" "https://${DOMAIN_HOST}/translate" || true)"
[ "$noauth" = "400" ] || die "a keyless translate call returned ${noauth}, not 400. Stop and investigate."

# End to end: a sentence in, Spanish out.
curl -sS --data-urlencode "q=Hello world" --data-urlencode "source=en" --data-urlencode "target=es" --data-urlencode "api_key@${KEY_FILE}" "https://${DOMAIN_HOST}/translate" | grep -q '"translatedText"' \
	|| die "a keyed translate call did not return a translation. Check: docker compose logs --tail 40 libretranslate"

curl -sS "https://${DOMAIN_HOST}/" | grep -q 'Translation API' \
	|| die "the first screen does not carry the heading Translation API. Check that Caddy is reaching the container."

# --- 7. The first backup, before day one ends --------------------------------
#
# The models are not in it, on purpose: 2.1 GB of cache that downloads itself
# again. The Caddy file archived here is the live one, with the real hostname
# already substituted.

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/libretranslate-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml api-key db -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/libretranslate-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	LibreTranslate is answering at https://${DOMAIN_HOST}

	  1. The first screen is a text box under the heading Translation API. It
	     also carries a banner about bot abuse and API keys: that is upstream's
	     own wording for the mode this install runs in, not a fault.
	  2. Your API key is in $KEY_FILE, mode 600. Read it with
	       cat $KEY_FILE
	     and put it in your password manager. It was not printed here. In the
	     browser, click the key icon in the top bar and paste it once.
	  3. Eleven languages are installed: en, es, fr, de, it, pt, nl, pl, ru, zh
	     and ja, each paired with English and pivoted through it for the rest.
	     To change that set, edit LT_LOAD_ONLY in $APP_DIR/compose.yml and
	     restart; the new models download on the next start.
	  4. First backup written to $APP_DIR/backups: the key, the key database,
	     the compose file and the Caddy block. It is on the same disk as the
	     data, which is not a backup. Copy it somewhere else tonight, and treat
	     it as a secret, because it carries your key twice.

DONE
