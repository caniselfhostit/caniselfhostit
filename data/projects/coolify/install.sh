#!/usr/bin/env bash
# Coolify · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=deploy.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://coolify.io/docs/get-started/installation
#   https://coolify.io/docs/knowledge-base/server/openssh
#   https://coolify.io/docs/knowledge-base/server/proxies
#   https://coolify.io/docs/knowledge-base/server/firewall
#
# Read this part before you run it. Coolify manages Docker on the machine it
# deploys to, and it reaches that machine over SSH, even when the machine is the
# one it is installed on. So this script generates a key, puts the public half
# in your own authorized_keys, gives the container the private half, and adds a
# passwordless sudo line for your account, which is upstream's documented
# requirement for a non-root user. The plain reading: that key is root on this
# box, and whoever reaches the dashboard reaches the box. Upstream's own
# installer arrives at the same place by enabling a root login instead.
#
# Seven secrets are generated here: the instance id, the application key, the
# database password, the Redis password and three realtime credentials. All go
# into /data/coolify/source/.env, mode 640 so the container's uid 9999 can read
# it, and none is ever printed.
#
# The server's proxy is left for you to set to Custom (None) in the dashboard,
# because the host's Caddy already owns 80 and 443. Step 7 of prompt.md says so
# and this script prints the same instruction at the end.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/data/coolify}"
BACKUP_DIR="${BACKUP_DIR:-/srv/coolify/backups}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. deploy.example.com"
[ "$(id -u)" -ne 0 ] || die "run this as your login user, not root. The key this creates is bound to that account."
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; four services plus builds want 2048 MB"
avail_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 30 ] || die "only ${avail_gb} GB free on /; this install wants 30 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out, make the key, open the sudo path ------------------
#
# /data/coolify is not a choice: the application writes deployment files to that
# path by name on the machine it manages. Our archives live outside it.

sudo install -d -m 750 -o "$(id -u)" -g 9999 "$APP_DIR" "$APP_DIR/source"
sudo install -d -m 700 -o 9999 -g 9999 \
	"$APP_DIR/ssh" "$APP_DIR/ssh/keys" "$APP_DIR/ssh/mux" \
	"$APP_DIR/applications" "$APP_DIR/databases" "$APP_DIR/services" \
	"$APP_DIR/backups" "$APP_DIR/proxy" "$APP_DIR/proxy/dynamic"
sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" /srv/coolify "$BACKUP_DIR"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/source/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/source/Caddyfile"

# The user name lives in the key's filename: the application reads it out of
# there to decide which account to log in as. Do not rename this file.
KEY="$APP_DIR/ssh/keys/id.$(id -un)@host.docker.internal"
if ! sudo test -f "$KEY"; then
	sudo ssh-keygen -t ed25519 -a 100 -N "" -C coolify -q -f "$KEY"
	install -d -m 700 "$HOME/.ssh"
	sudo cat "$KEY.pub" >> "$HOME/.ssh/authorized_keys"
	chmod 600 "$HOME/.ssh/authorized_keys"
	sudo rm -f "$KEY.pub"
	sudo chown 9999:9999 "$KEY"
	sudo chmod 600 "$KEY"
fi

printf '%s ALL=(ALL) %s ALL\n' "$(id -un)" 'NOPASSWD:' | sudo tee /etc/sudoers.d/coolify >/dev/null
sudo chmod 440 /etc/sudoers.d/coolify
sudo visudo -c -f /etc/sudoers.d/coolify || die "the sudoers drop-in did not parse. Remove /etc/sudoers.d/coolify now."

docker network create --attachable coolify >/dev/null 2>&1 || true

# --- 3. Generate the seven secrets, on the server ----------------------------
#
# Hex for the two that travel inside connection strings. Read them later with
#   sudo grep APP_KEY /data/coolify/source/.env

if [ ! -f "$APP_DIR/source/.env" ]; then
	umask 077
	cat > "$APP_DIR/source/.env" <<-ENVFILE
		APP_ID=$(openssl rand -hex 16)
		APP_NAME=Coolify
		AUTOUPDATE=false
		APP_KEY=base64:$(openssl rand -base64 32)
		DB_USERNAME=coolify
		DB_DATABASE=coolify
		DB_PASSWORD=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
		PUSHER_APP_ID=$(openssl rand -hex 32)
		PUSHER_APP_KEY=$(openssl rand -hex 32)
		PUSHER_APP_SECRET=$(openssl rand -hex 32)
	ENVFILE
	umask 022
	sudo chown "$(id -u)":9999 "$APP_DIR/source/.env"
	chmod 640 "$APP_DIR/source/.env"
fi

cd "$APP_DIR/source"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------
#
# Three routes: the dashboard on 8115, live deployment logs on 6001, the web
# terminal on 6002. Upstream's own proxy splits the hostname the same way.

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-coolify"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/source/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of the five app ports is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8115, 6001, 6002, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The application migrates its own database on the way up, so a cold pull takes
# several minutes. That is what the loop below is for.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 coolify"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q 'OK' \
	|| die "/api/health answered 200 without OK. Check: docker compose logs --tail 40 coolify"

# A fresh instance sends every visitor to the registration screen. Both of these
# are the same assert from two directions: the redirect target and the heading.
landing="$(curl -sSL -o /dev/null -w '%{url_effective}' "https://${DOMAIN_HOST}/" || true)"
[ "$landing" = "https://${DOMAIN_HOST}/register" ] \
	|| die "https://${DOMAIN_HOST}/ landed on ${landing}, not the registration screen. Stop and investigate."
curl -sSL "https://${DOMAIN_HOST}/register" | grep -q 'Create your account' \
	|| die "the first screen does not carry 'Create your account'. Check: docker compose logs --tail 40 coolify"

docker compose ps

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U coolify -d coolify | gzip > "$BACKUP_DIR/coolify-db-${STAMP}.sql.gz"
sudo tar -czf "$BACKUP_DIR/coolify-config-${STAMP}.tar.gz" -C "$APP_DIR" source ssh -C /etc/caddy Caddyfile
ls -lh "$BACKUP_DIR/"
[ -s "$BACKUP_DIR/coolify-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$BACKUP_DIR/coolify-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Coolify is answering at https://${DOMAIN_HOST}/api/health

	  1. Open https://${DOMAIN_HOST} now. The first screen says "Create your
	     account" under the heading Coolify, with a Root User Setup notice.
	     Make that account there. It is the only moment it can be made:
	     registration closes itself once the first user exists, and there is
	     no mail server here to reset the password. Save it first.
	  2. Then three things in the dashboard, and the middle one matters most:
	       - Settings: set the instance's domain to https://${DOMAIN_HOST}
	       - Servers > localhost > Proxy: choose Custom (None), until the page
	         reads "Custom (None) Proxy Selected". Traefik and Caddy both want
	         ports 80 and 443, which the host's Caddy already holds. Until you
	         set this, Coolify keeps trying to start a proxy and failing.
	       - Servers > localhost: press Validate and confirm it is reachable.
	     Confirm with:
	       docker ps -a --filter name=coolify-proxy --format '{{.Names}} {{.Status}}'
	     Nothing, or an Exited container, is what you want.
	  3. Applications you deploy on this box get a host port and a site block
	     in /etc/caddy/Caddyfile, the same way this dashboard did. The domain
	     field in the dashboard routes nothing while the proxy is Custom.
	  4. Your seven secrets are in $APP_DIR/source/.env, mode 640, and none was
	     printed here. APP_KEY is the one to keep: the database is encrypted
	     with it, so a dump restored without that file is unreadable.
	  5. First backup written to $BACKUP_DIR: a database dump and a config
	     archive holding source/, the host key and the Caddy site block. They
	     are on the same disk as the data, which is not a backup. Copy both
	     somewhere else tonight, and keep them together.

DONE
