#!/usr/bin/env bash
# changedetection.io · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=watch.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/dgtlmoon/changedetection.io/blob/0.55.8/README.md#docker
#   https://github.com/dgtlmoon/changedetection.io/wiki/Password-protection
#   https://github.com/dgtlmoon/changedetection.io/blob/0.55.8/changedetectionio/flask_app.py
#   https://github.com/dgtlmoon/changedetection.io/wiki/Playwright-content-fetcher
#
# One secret is generated here: a random UI password. The app does not read a
# PASSWORD env var. It checks SALTED_PASS, a base64(salt + pbkdf2-hmac-sha256)
# value built the same way upstream's SaltyPasswordField does. Both the plain
# password (for you) and SALTED_PASS (for the app) land in .env mode 600.
#
# This install does not ship Playwright or sockpuppetbrowser. JavaScript-heavy
# pages need that second container; see the prompts for the upgrade path.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/changedetection}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. watch.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is required to build SALTED_PASS the way upstream does"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the UI password and SALTED_PASS -----------------------------
#
# Matches SaltyPasswordField.build_password at tag 0.55.8: 32-byte salt,
# pbkdf2_hmac sha256 100000 rounds, base64(salt + key). The plain password is
# stored only so you can type it; the app reads SALTED_PASS.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	LOGIN_PASSWORD="$(openssl rand -base64 24)"
	export LOGIN_PASSWORD
	SALTED_PASS="$(python3 - <<'PY'
import base64, hashlib, os, secrets
plain = os.environ.get("LOGIN_PASSWORD", "").encode("utf-8")
salt = secrets.token_bytes(32)
key = hashlib.pbkdf2_hmac("sha256", plain, salt, 100000)
print(base64.b64encode(salt + key).decode("ascii"))
PY
)"
	cat > "$APP_DIR/.env" <<-ENVFILE
		BASE_URL=https://${DOMAIN_HOST}
		LOGIN_PASSWORD=${LOGIN_PASSWORD}
		SALTED_PASS=${SALTED_PASS}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
	unset LOGIN_PASSWORD SALTED_PASS
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-changedetection"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8205 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8205 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	# Password-protected: unauthenticated GET redirects to the login form.
	case "$code" in 200|301|302|303|307|308) break ;; esac
	sleep 5
done
[ -n "${code:-}" ] || die "no HTTP response from https://${DOMAIN_HOST}/"

# Unauthenticated access must not serve the dashboard.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/")"
case "$unauth" in
	302|401|403) ;;
	*) die "unauthenticated GET returned ${unauth}; expected redirect or refusal. Check: docker compose logs --tail 40 changedetection" ;;
esac
curl -sSL "https://${DOMAIN_HOST}/" | grep -qi 'password' \
	|| die "login page does not carry a password field after redirect"

# --- 7. First backup ---------------------------------------------------------
#
# data/ is the /datastore mount: watches, history, settings. .env holds the
# hash and the human password. Live Caddyfile via the two -C form.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/changedetection-${STAMP}.tar.gz" \
	-C "$APP_DIR" data compose.yml .env \
	-C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/changedetection-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	changedetection.io is answering at https://${DOMAIN_HOST}

	  1. Read the UI password once:
	       grep LOGIN_PASSWORD $APP_DIR/.env
	     Put it in your password manager. Do not leave it only on this disk.
	  2. Open https://${DOMAIN_HOST}/ , sign in, add a watch. This install has
	     no Playwright/sockpuppetbrowser: JS-rendered prices need that sidecar
	     later (wiki Playwright-content-fetcher).
	  3. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.
	  4. NOT YET VERIFIED on a clean harness machine.

DONE
