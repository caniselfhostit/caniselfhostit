#!/usr/bin/env bash
# code-server · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=code.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://coder.com/docs/code-server/install
#   https://coder.com/docs/code-server/FAQ
#   https://coder.com/docs/code-server/requirements
#   https://coder.com/docs/code-server/guide
#   https://github.com/coder/code-server/blob/v4.131.0/ci/release-image/Dockerfile
#
# Read this before you run it. code-server is VS Code with a browser front end,
# and VS Code ships an integrated terminal, so DOMAIN_HOST becomes a shell on
# this server behind one password. That password is generated here, written to
# /srv/code-server/.env with mode 600, and never printed. Read it yourself with
#   grep PASSWORD /srv/code-server/.env
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/code-server}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
PORT=8137

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. code.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; upstream's floor is 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The image runs as uid 1000, the `coder` user baked into it, so three of the
# four directories belong to that uid rather than to the login user.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 750 -o 1000 -g 1000 "$APP_DIR/local" "$APP_DIR/project"
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/config" "$APP_DIR/config/code-server"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# Upstream writes this file itself on first start, with a random password in it,
# and refuses to overwrite one that exists. Writing it first keeps that second
# credential-shaped string off the disk and turns telemetry off before a request
# leaves the box. No `password` line: step 3 supplies that from the environment.
if [ ! -f "$APP_DIR/config/code-server/config.yaml" ]; then
	cat > "$APP_DIR/config/code-server/config.yaml" <<-'CONFIG'
		auth: password
		disable-telemetry: true
		disable-update-check: true
	CONFIG
fi
sudo chown -R 1000:1000 "$APP_DIR/config"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: Docker Compose reads this same file for variable
# interpolation and a `$` inside the value would be expanded. Sixty-four hex
# characters is 256 bits, which is not overkill on a login that is also a shell.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-code-server"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8137 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; ${PORT} stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthz"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthz" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/healthz answered ${code:-nothing}. Check: docker compose logs --tail 40 code-server"

# The heartbeat reads "expired" until a browser holds the editor open, so the
# assert is on the shape of the response rather than on that word.
curl -sS "https://${DOMAIN_HOST}/healthz" | grep -q 'lastHeartbeat' \
	|| die "/healthz answered 200 without a heartbeat field. Check: docker compose logs --tail 40 code-server"

# An unauthenticated request must be sent to the login page. This decides
# whether the install is safe to leave running.
root_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$root_code" = "302" ] || die "an unauthenticated request to / returned ${root_code}, not 302. Authentication is not on. Stop."

# code-server prints this line only when the password came from the
# environment, so it proves the .env value reached the container.
login_page="$(curl -sS "https://${DOMAIN_HOST}/login" || true)"
printf '%s' "$login_page" | grep -q 'Welcome to code-server' \
	|| die "the login page did not render. Check: docker compose logs --tail 40 code-server"
printf '%s' "$login_page" | grep -q 'Password was set from' \
	|| die "the login page is not using the generated password. Check that ${APP_DIR}/.env exists and holds one line."
unset login_page

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/code-server-${STAMP}.tar.gz" -C "$APP_DIR" config local project compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/code-server-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	code-server is answering at https://${DOMAIN_HOST}

	  1. Your password is in $APP_DIR/.env, mode 600. Read it with
	       grep PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here.
	     Sign in at https://${DOMAIN_HOST} with that value and no username.
	  2. This hostname is a shell on this server. The editor's terminal runs
	     inside the container as uid 1000, on the three folders under
	     $APP_DIR, and the Docker socket is deliberately not mounted.
	  3. The folder on the left is /home/coder/project and it is empty. Fill
	     it with a git clone from the editor's own terminal.
	  4. Extensions come from Open VSX, not Microsoft's marketplace. Live
	     Share and the Remote extensions are not available on either.
	  5. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
