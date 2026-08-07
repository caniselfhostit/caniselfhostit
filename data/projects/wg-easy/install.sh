#!/usr/bin/env bash
# wg-easy · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=vpn.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/getting-started.md
#   https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/examples/tutorials/basic-installation.md
#   https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/advanced/config/optional-config.md
#   https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/advanced/config/unattended-setup.md
#   https://github.com/wg-easy/wg-easy/blob/v15.3.0/docs/content/faq.md
#
# One secret is generated here, on this machine: the password for the admin
# account the container creates on its first start. It goes into
# /srv/wg-easy/.env with mode 600 and is never printed.
#
# DOMAIN_HOST is also INIT_HOST, the address every client configuration this
# server hands out will dial. Choose it once.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/wg-easy}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. vpn.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# WireGuard is a kernel module. Upstream names a missing one as the cause of
# 'Cannot find device "wg0"', and no container setting works around it.
sudo modprobe wireguard 2>/dev/null || true
[ "$(lsmod | grep -c '^wireguard')" -ge 1 ] \
	|| die "this kernel has no WireGuard module. That is usually an old kernel or a container-based VPS plan."
echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf >/dev/null

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/etc_wireguard"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Upstream reads the INIT_ group only during the container's first start and
# recommends removing the variables afterwards; section 7 below does that.
# Read the password before then with
#   sudo grep INIT_PASSWORD /srv/wg-easy/.env
# INIT_DNS and INIT_ALLOWED_IPS carry one value each because DISABLE_IPV6 is
# true in compose.yml, so a client must not be handed an IPv6 route.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		INIT_ENABLED=true
		INIT_USERNAME=admin
		INIT_PASSWORD=$(openssl rand -base64 24)
		INIT_HOST=${DOMAIN_HOST}
		INIT_PORT=51820
		INIT_DNS=1.1.1.1
		INIT_ALLOWED_IPS=0.0.0.0/0
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-wg-easy"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: four open, and 8133 is not one of them ------------------------
#
# 51820/udp is the tunnel itself. Browsers and phones speak WireGuard straight
# to it and no reverse proxy can carry that, so it is published to the world.
# The socket stays silent to any packet it cannot verify against a key this
# install issued.

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3, 51820/udp for WireGuard; 8133 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw allow 51820/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/login"
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/login" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/login answered ${code:-nothing}. Check: docker compose logs --tail 40 wg-easy"

curl -sS -H 'Accept-Language: en' "https://${DOMAIN_HOST}/login" | grep -q 'Sign In' \
	|| die "/login answered 200 without the Sign In form. Check: docker compose logs --tail 40 wg-easy"

# The tunnel has to exist, not only the web server. This is the container's own
# health check, run once here so a failure stops the script.
docker compose exec -T wg-easy wg show | grep -q '^interface: wg0' \
	|| die "wg show printed no wg0 interface. Check: docker compose logs --tail 40 wg-easy"
docker compose exec -T wg-easy wg show | grep -q 'listening port: 51820' \
	|| die "wg0 exists but is not listening on 51820. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose down
sudo tar -czf "$APP_DIR/backups/wg-easy-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env etc_wireguard -C /etc/caddy Caddyfile
docker compose up -d
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/wg-easy-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	wg-easy is answering at https://${DOMAIN_HOST}/login

	  1. Sign in as admin. Your password is in $APP_DIR/.env, mode 600:
	       sudo grep INIT_PASSWORD $APP_DIR/.env
	     Put it in your password manager now. It was not printed here.
	  2. Then delete those lines, which is what upstream recommends once the
	     setup has run:
	       sed -i '/^INIT_/d' $APP_DIR/.env
	       cd $APP_DIR && docker compose up -d --force-recreate
	     The account and the clients are in the database from here on. A
	     forgotten password is reset with
	       docker compose exec -it wg-easy cli db:admin:reset
	  3. Add your first client in the web interface and scan its QR code with
	     the WireGuard app. Confirm the tunnel end to end with
	       docker compose exec -T wg-easy wg show
	     which grows a "latest handshake" line once a device connects. A
	     running container is not success.
	  4. First backup written to $APP_DIR/backups. It holds the private key of
	     every device you enrol, so it is on the same disk as the data, which is
	     not a backup, and it belongs somewhere encrypted. Copy it off tonight.

DONE
