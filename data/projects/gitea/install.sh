#!/usr/bin/env bash
# Gitea · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=git.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.gitea.com/installation/install-with-docker
#   https://docs.gitea.com/administration/config-cheat-sheet
#   https://docs.gitea.com/administration/reverse-proxies
#
# No secret is generated here. The first browser visitor to complete the install
# wizard creates the admin account (first claimant). This script starts with
# registration open, prints how to claim the instance, and leaves DISABLE_REGISTRATION
# false until you flip it after that account exists (see the summary).
#
# Git over HTTPS with a personal access token is the documented path. SSH is not
# published on this host.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/gitea}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. git.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data/ is the whole state: git repos, SQLite, attachments, avatars, app.ini.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"
sed -i "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/compose.yml"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 3. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-gitea"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 4. Ports: two open, and 8208 is not one of them -------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8208 and 22 stay as they were"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 5. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/"
for _ in $(seq 1 36); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
	case "$code" in 200|301|302|303|307|308) break ;; esac
	sleep 5
done
[ -n "${code:-}" ] || die "no HTTP response from https://${DOMAIN_HOST}/"

curl -sSL "https://${DOMAIN_HOST}/" | grep -qi 'gitea\|install\|register\|sign' \
	|| die "the page at https://${DOMAIN_HOST}/ does not look like Gitea. Check: docker compose logs --tail 40 gitea"

# --- 6. First backup of the empty-but-initialized data dir -------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/gitea-${STAMP}.tar.gz" \
	-C "$APP_DIR" data compose.yml \
	-C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/gitea-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Gitea is answering at https://${DOMAIN_HOST}

	  1. Open https://${DOMAIN_HOST}/ now and finish the install wizard. The first
	     account you create is the admin (first claimant). Do this before anyone
	     else can reach the hostname.
	  2. After that account exists, close registration:
	       cd $APP_DIR
	       sed -i 's/GITEA__service__DISABLE_REGISTRATION: "false"/GITEA__service__DISABLE_REGISTRATION: "true"/' compose.yml
	       docker compose up -d
	     Then confirm signup is gone: open https://${DOMAIN_HOST}/user/sign_up in a
	     private window and check that no registration form is offered. Also:
	       grep -c 'DISABLE_REGISTRATION: "true"' $APP_DIR/compose.yml
	     must print 1.
	  3. Git over HTTPS: create a personal access token under Settings, then:
	       git clone https://${DOMAIN_HOST}/<you>/<repo>.git
	       git push  (username + token as password)
	     SSH is not published by this install.
	  4. First backup written to $APP_DIR/backups. Copy it off this disk tonight.
	  5. NOT YET VERIFIED on a clean harness machine.

DONE
