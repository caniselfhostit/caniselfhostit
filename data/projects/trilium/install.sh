#!/usr/bin/env bash
# Trilium · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=notes.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.triliumnotes.org/user-guide/setup/server/installation/docker
#   https://docs.triliumnotes.org/user-guide/advanced-usage/configuration
#   https://docs.triliumnotes.org/user-guide/setup/server/reverse-proxy/trusted-proxy
#   https://docs.triliumnotes.org/user-guide/setup/backup
#   https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# One secret is generated here, on this machine: the password you will type into
# Trilium's own set-password screen. It goes into /srv/trilium/login-password at
# mode 600 and it is never printed. Read it yourself with
#   sudo cat /srv/trilium/login-password
#
# Trilium has no account of its own until a human opens a browser and finishes
# the setup wizard, and until that happens anyone who can reach the hostname can
# finish it instead of you. This script therefore stops and waits for you to do
# it, and refuses to call the install done until the instance answers that it
# now requires a login.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/trilium}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. notes.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data is left owned by root at 700. The Trilium image starts as root, chowns
# its data directory to the node user inside the container and then drops to
# that user, so an ownership fix here would be undone on the next start.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Base64 rather than hex: this value is pasted into a browser form once and then
# into a password manager, so length matters more than typing comfort. It is not
# in an .env and it is not handed to the container. Trilium takes its password
# from a form a human fills in, so the credential belongs nowhere near the
# application's environment.

if [ ! -f "$APP_DIR/login-password" ]; then
	umask 077
	openssl rand -base64 24 > "$APP_DIR/login-password"
	chmod 600 "$APP_DIR/login-password"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-trilium"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8103 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8103 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health-check"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health-check" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/api/health-check answered ${code:-nothing}. Check: docker compose logs --tail 40 trilium"

curl -sS "https://${DOMAIN_HOST}/api/health-check" | grep -q '"status":"ok"' \
	|| die "/api/health-check answered 200 without status ok. Check: docker compose logs --tail 40 trilium"

curl -sS "https://${DOMAIN_HOST}/bootstrap" | grep -q '"triliumVersion":"0.104.1"' \
	|| die "the running server did not report version 0.104.1. Check the image line in $APP_DIR/compose.yml"

# --- 7. The part only a human can do -----------------------------------------
#
# Until the wizard has run and a password exists, every request is served
# without authentication. That is upstream's design for a brand new database and
# it is why this script blocks here rather than reporting success.

cat <<-WAITING

	Open https://${DOMAIN_HOST} in a browser now, not later.

	  1. The first screen is headed "Language". Pick one and press Continue.
	  2. The next screen is headed "Get started with Trilium". Choose
	     "New knowledge base", then "Empty".
	  3. When the screen headed "Set password" appears, read the password this
	     script generated, on this server, with
	       sudo cat $APP_DIR/login-password
	     and paste it into both fields.

	Until you finish that, this instance has no password and anyone who knows
	the hostname can finish the wizard instead of you. Waiting up to 15 minutes.

WAITING

echo "==> waiting for the instance to start requiring a login"
for _ in $(seq 1 90); do
	if curl -sS "https://${DOMAIN_HOST}/bootstrap" | grep -q '"loggedIn":false'; then
		locked=yes
		break
	fi
	sleep 10
done
[ "${locked:-}" = "yes" ] || die "the instance still serves without a login. Finish the wizard at https://${DOMAIN_HOST}, then re-run the backup section by hand."

# --- 8. The first backup, before day one ends --------------------------------
#
# Trilium keeps its notes in a SQLite database it writes continuously, so the
# container is stopped for the few seconds the archive takes.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/trilium-${STAMP}.tar.gz" -C "$APP_DIR" data login-password compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/trilium-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Trilium is answering at https://${DOMAIN_HOST} and now requires a login.

	  1. Your password is in $APP_DIR/login-password, mode 600. Read it with
	       sudo cat $APP_DIR/login-password
	     and put it in your password manager. It was not printed here. Changing
	     it later is done inside Trilium, under Options, and this file is not
	     updated when you do.
	  2. Trilium keeps its own rolling copies of the database under
	     $APP_DIR/data/backup: one daily, one weekly, one monthly, plus one
	     taken before each version migration. Those are on the same disk as the
	     original, so they are a convenience, not a backup.
	  3. First backup written to $APP_DIR/backups. It holds the database and
	     the password file, and it is on the same disk as the data, which is not
	     a backup. Copy it off this machine tonight, from your own machine:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/trilium/
	  4. There is one account. Trilium does not support multiple users, so a
	     second person means a second container with its own data directory and
	     its own hostname.

DONE
