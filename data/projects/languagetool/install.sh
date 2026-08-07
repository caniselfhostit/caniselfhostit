#!/usr/bin/env bash
# LanguageTool · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=lt.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://dev.languagetool.org/http-server
#   https://github.com/languagetool-org/languagetool/blob/v6.8/README.md
#   https://github.com/Erikvl87/docker-languagetool/blob/v6.8/README.md
#   https://github.com/Erikvl87/docker-languagetool/blob/v6.8/Dockerfile
#   https://caddyserver.com/docs/caddyfile/directives/basic_auth
#
# One secret is generated here, on this machine: the password Caddy checks in
# front of the API. It goes into /srv/languagetool/api-password with mode 600 and
# is never printed. The LanguageTool HTTP server has no accounts and no API key
# of its own, and the image starts it with --public and --allow-origin '*', so
# that Caddy credential is the only access control this install has.
#
# Needs Caddy 2.8 or newer: that release renamed basicauth to basic_auth.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/languagetool}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. lt.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

caddy_ver="$(caddy version | head -1 | cut -d' ' -f1 | sed 's/^v//')"
caddy_major="${caddy_ver%%.*}"
caddy_rest="${caddy_ver#*.}"
caddy_minor="${caddy_rest%%.*}"
if [ "$caddy_major" -lt 2 ] || { [ "$caddy_major" -eq 2 ] && [ "$caddy_minor" -lt 8 ]; }; then
	die "caddy ${caddy_ver} predates 2.8, where the basic_auth directive this install uses arrived"
fi

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; a JVM with a 1 GB heap wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# No data directory, on purpose. LanguageTool reads its rules and dictionaries
# out of the image and keeps nothing between requests.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: this value gets typed into settings boxes on other
# machines and hex has nothing a keyboard layout can ruin. Read it later with
#   sudo cat /srv/languagetool/api-password
# The .netrc is the same credential in the form curl reads from a file, which
# keeps it out of the process list and out of shell history.

if [ ! -f "$APP_DIR/api-password" ]; then
	umask 077
	openssl rand -hex 24 > "$APP_DIR/api-password"
	printf 'machine %s login languagetool password %s\n' "$DOMAIN_HOST" "$(cat "$APP_DIR/api-password")" > "$APP_DIR/.netrc"
	chmod 600 "$APP_DIR/api-password" "$APP_DIR/.netrc"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. The login box, then the site block, both on the host -----------------

umask 077
caddy hash-password < "$APP_DIR/api-password" > "$APP_DIR/auth.hash"
printf 'basic_auth {\n\tlanguagetool %s\n}\n' "$(cat "$APP_DIR/auth.hash")" > "$APP_DIR/auth.conf"
umask 022
sudo install -m 640 -o root -g caddy "$APP_DIR/auth.conf" /etc/caddy/languagetool-auth.conf
rm -f "$APP_DIR/auth.hash" "$APP_DIR/auth.conf"

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-languagetool"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8149 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8149 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for the container on http://127.0.0.1:8149/v2/languages"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:8149/v2/languages" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/v2/languages answered ${code:-nothing}. Check: docker compose logs --tail 40 languagetool"

curl -sS "http://127.0.0.1:8149/v2/languages" | grep -q '"longCode":"en-US"' \
	|| die "the languages listing has no en-US in it. Check: docker compose logs --tail 40 languagetool"

# Caddy must refuse a call that carries no credential. A 200 here means the
# import line is not doing its job and the server is open to the internet.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/v2/languages" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated call returned ${unauth}, not 401. Stop and investigate."

# End to end: a sentence in, a grammar match out, through Caddy and the login.
checked="$(curl -sS --netrc-file "$APP_DIR/.netrc" -d "language=en-US" -d "text=I has a apple." "https://${DOMAIN_HOST}/v2/check" || true)"
printf '%s' "$checked" | grep -q '"name":"LanguageTool"' || die "the check response did not name LanguageTool"
printf '%s' "$checked" | grep -q 'EN_A_VS_AN' || die "the check response found no EN_A_VS_AN match in 'a apple'"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
sudo tar -czf "$APP_DIR/backups/languagetool-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml api-password .netrc -C /etc/caddy Caddyfile languagetool-auth.conf
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/languagetool-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	LanguageTool is answering at https://${DOMAIN_HOST}/v2

	  1. There is no web interface, and https://${DOMAIN_HOST}/ returns 404.
	     That is correct: this is an API, not a site. Point an editor plugin
	     or a script at https://${DOMAIN_HOST}/v2 with the username
	     languagetool and the password below.
	  2. Your password is in $APP_DIR/api-password, mode 600. Read it with
	       sudo cat $APP_DIR/api-password
	     and put it in your password manager. It was not printed here.
	  3. The LanguageTool browser add-on cannot use this server. Its settings
	     box takes a URL and nothing else, so it never answers the password
	     Caddy asks for, and a check that failed looks exactly like writing
	     with no mistakes in it. Either tunnel to it from your own machine
	       ssh -N -L 8149:127.0.0.1:8149 vps
	     and point the add-on at http://localhost:8149/v2, or run the local
	     install on your own computer instead.
	  4. First backup written to $APP_DIR/backups. It holds the password, so
	     it is as sensitive as a credential and it is on the same disk as the
	     install, which is not a backup. Copy it somewhere else tonight.

DONE
