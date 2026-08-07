#!/usr/bin/env bash
# SiYuan · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=notes.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/siyuan-note/siyuan/blob/v3.7.3/README.md
#   https://github.com/siyuan-note/siyuan/blob/v3.7.3/kernel/entrypoint.sh
#   https://github.com/siyuan-note/siyuan/blob/v3.7.3/docs/API.md
#   https://github.com/siyuan-note/siyuan/blob/v3.7.3/kernel/model/session.go
#
# One secret is generated here, on this machine: the lock screen code that gates
# the whole workspace. It goes into /srv/siyuan/.env with mode 600 and is never
# printed. There is no account behind it and no reset link.
#
# What this install is: the SiYuan application served over HTTP from one
# container, opened in a browser. Upstream states that the Docker deployment
# does not accept desktop or mobile application connections.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/siyuan}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. notes.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; the kernel and its index want 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# The workspace belongs to uid 1000 because the image entrypoint creates a user
# with that id and re-execs the kernel as it, chowning this directory on every
# start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 -o 1000 -g 1000 "$APP_DIR/workspace"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: the value is typed or pasted into a password box in a
# browser, and hex survives every clipboard on the way. Read it later with
#   sudo grep SIYUAN_ACCESS_AUTH_CODE /srv/siyuan/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		SIYUAN_ACCESS_AUTH_CODE=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-siyuan"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8141 nor 6806 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8141 and 6806 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The kernel builds its index on the first start, so this wait is doing real
# work rather than watching a socket.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/system/bootProgress to report 100"
for _ in $(seq 1 30); do
	boot="$(curl -sS "https://${DOMAIN_HOST}/api/system/bootProgress" || true)"
	printf '%s\n' "$boot" | grep -q '"progress":100' && break
	sleep 10
done
printf '%s\n' "${boot:-}" | grep -q '"progress":100' \
	|| die "boot progress never reached 100. Check: docker compose logs --tail 40 siyuan"

# The pin confirming itself. util.Ver carries no leading v.
curl -sS "https://${DOMAIN_HOST}/api/system/version" | grep -q '"data":"3.7.3"' \
	|| die "/api/system/version did not report 3.7.3. Check: docker compose logs --tail 40 siyuan"

# The gate. Upstream answers a non-browser request with 401 and redirects a
# browser to the unlock page, so both codes have to be what they are.
plain="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$plain" = "401" ] || die "the root URL answered ${plain}, not 401. The workspace may be ungated. Stop and investigate."

browser="$(curl -sS -A 'Mozilla/5.0' -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$browser" = "302" ] || die "a browser request to the root URL answered ${browser}, not 302"

curl -sS "https://${DOMAIN_HOST}/check-auth" | grep -q 'Unlock access' \
	|| die "the unlock page did not render. Check: docker compose logs --tail 40 siyuan"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/siyuan-${STAMP}.tar.gz" -C "$APP_DIR" workspace compose.yml .env -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/siyuan-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	SiYuan is answering at https://${DOMAIN_HOST}

	  1. The first screen is the unlock page: one password box and an
	     "Unlock access" button. Your lock screen code is in $APP_DIR/.env,
	     mode 600. Read it with
	       sudo grep SIYUAN_ACCESS_AUTH_CODE $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and
	     there is no account behind it and no reset link.
	  2. Open the site in a browser and unlock it. A bare curl of the root URL
	     answers 401 on purpose: the kernel redirects browsers to the unlock
	     page and refuses everything else.
	  3. The browser is the client. Upstream states that this deployment does
	     not accept desktop or mobile application connections, and the sync
	     settings inside the app are gated behind a paid SiYuan account, so
	     leave them alone. Every device opens this one workspace instead.
	  4. First backup written to $APP_DIR/backups: the workspace, the compose
	     file, the env file and the live Caddy block. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight.

DONE
