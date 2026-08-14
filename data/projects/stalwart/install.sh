#!/usr/bin/env bash
# Stalwart · the agent-free install.
#
# Everything prompt.md tells an agent to do up to the setup wizard, as a script
# you can read first. Run it on the VPS, as a non-root user in the docker group:
#
#   DOMAIN_HOST=mail.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation and from the
# source at the pinned tag:
#   https://stalw.art/docs/install/platform/docker
#   https://stalw.art/docs/install/security
#   https://stalw.art/docs/install/requirements
#   https://stalw.art/docs/install/dns
#   https://github.com/stalwartlabs/stalwart/blob/v0.16.17/Dockerfile
#
# One secret is generated here, on this machine: the bootstrap administrator
# credential. It goes into /srv/stalwart/.env with mode 600 and is never
# printed. Setting it in advance is deliberate. Left unset, Stalwart generates
# its own and writes it to the container log in clear text, once, where anyone
# who can read `docker logs` can read it afterwards.
#
# DOMAIN_HOST is the mail host, for example mail.example.com. It becomes
# STALWART_HOSTNAME, the name this server gives other servers in SMTP EHLO, and
# it must match the PTR record of this box's IP address. Use one label in front
# of your domain rather than the bare domain: your addresses live at the domain
# underneath it.
#
# This script stops at the setup wizard, because only a human can complete it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/stalwart}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the mail hostname you pointed at this server, e.g. mail.example.com"
case "$DOMAIN_HOST" in
	*.*.*) : ;;
	*) die "$DOMAIN_HOST looks like a bare domain. Use a host under it, e.g. mail.$DOMAIN_HOST" ;;
esac
MAIL_DOMAIN="$(printf '%s' "$DOMAIN_HOST" | cut -d. -f2-)"

command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v dig >/dev/null 2>&1 || die "dig is not installed (apt-get install dnsutils)"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; this install wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; mail grows, this install wants 10 GB"

resolved="$(dig +short "$DOMAIN_HOST" | tail -1)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."
ptr="$(dig +short -x "$resolved" | tail -1)" || ptr=""
echo "==> $DOMAIN_HOST resolves to $resolved, whose PTR record reads: ${ptr:-none}"
if [ "$ptr" != "${DOMAIN_HOST}." ]; then
	echo "==> WARNING: that PTR record does not read ${DOMAIN_HOST}. Large receivers read a"
	echo "==> mismatch as a forgery signal. Set reverse DNS for $resolved in your hosting"
	echo "==> provider's control panel before you send mail to anyone who matters."
fi

echo "==> testing whether this provider lets you open port 25 outbound"
if timeout 10 bash -c 'exec 3<>/dev/tcp/aspmx.l.google.com/25' 2>/dev/null; then
	echo "==> outbound 25 is OPEN"
else
	die "outbound port 25 is blocked here. Most VPS providers block it by default and unblock it on request, and until they do, this server can receive mail and deliver none of it. Ask them first, then run this again."
fi

# --- 2. Lay the files out ----------------------------------------------------
#
# The image runs as uid 2000, so the three directories it writes are owned by
# 2000 rather than by you. /etc/stalwart holds config.json, /var/lib/stalwart
# holds the RocksDB with every message and every setting, /var/log/stalwart is
# where the setup wizard's default log destination points.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 -o 2000 -g 2000 "$APP_DIR/etc" "$APP_DIR/data" "$APP_DIR/log"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the one secret, on the server -------------------------------
#
# Hex rather than base64: the value travels as the password half of a
# user:secret pair, and Stalwart reads a leading $, _ or { as a hash prefix,
# none of which hex can produce. Read it later with
#   sudo grep STALWART_RECOVERY_ADMIN /srv/stalwart/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		STALWART_HOSTNAME=${DOMAIN_HOST}
		STALWART_PUBLIC_URL=https://${DOMAIN_HOST}
		STALWART_RECOVERY_ADMIN=admin:$(openssl rand -hex 24)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-stalwart"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: six open, and 8189 is not one of them -------------------------
#
# 80 and 443 are Caddy's. 25 is how other mail servers reach you, 465 is how
# your clients send, 993 is how they read. Docker publishes 25, 465 and 993 by
# writing its own iptables rules, which are consulted before ufw's, so those
# three are reachable whether or not ufw lists them: the compose ports list is
# the real control and these rules record the intent.

if command -v ufw >/dev/null 2>&1; then
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw allow 25/tcp
	sudo ufw allow 465/tcp
	sudo ufw allow 993/tcp
	sudo ufw status verbose
fi

# --- 6. Start it, in bootstrap mode ------------------------------------------
#
# With no config.json present Stalwart opens exactly one listener, plain HTTP
# on 8080, and offers the setup wizard at /admin. No mail port is listening
# yet: those appear after the wizard writes config.json and the container is
# restarted.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthz/live"
code=""
for _ in $(seq 1 30); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthz/live" 2>/dev/null)" || code="000"
	if [ "$code" = "200" ]; then break; fi
	sleep 10
done
[ "$code" = "200" ] || die "/healthz/live answered ${code}. Check: docker compose logs --tail 40 stalwart"

admin_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/admin/" 2>/dev/null)" || admin_code="000"
[ "$admin_code" = "200" ] || die "/admin/ answered ${admin_code}, not 200. The web interface is downloaded from GitHub on first start, and both /admin and /account answer 404 until that download succeeds. Check outbound HTTPS, then: docker compose logs --tail 40 stalwart"

curl -sS "https://${DOMAIN_HOST}/login" | grep -q '<title>Sign in</title>' \
	|| die "the sign-in page did not render. Check: docker compose logs --tail 40 stalwart"

unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/account" 2>/dev/null)" || unauth="000"
[ "$unauth" = "401" ] || die "an unauthenticated admin API call returned ${unauth}, not 401. Stop and investigate."

if sudo test -e "$APP_DIR/etc/config.json"; then
	die "$APP_DIR/etc/config.json already exists, so this server is not in bootstrap mode and the wizard will refuse. Stop and work out which earlier run created it."
fi

# --- 7. The first backup, before the wizard ----------------------------------
#
# The container is stopped for the copy. RocksDB is a set of files being
# written, and a tar of one taken mid-write is not a backup.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/stalwart-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env etc data -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/stalwart-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Stalwart is in bootstrap mode at https://${DOMAIN_HOST}/admin

	  1. Sign in as the user admin. Read the credential once with
	       sudo grep STALWART_RECOVERY_ADMIN $APP_DIR/.env
	     The part after the colon is what you type. It was not printed here.
	  2. Complete the setup wizard. Leave the hostname as ${DOMAIN_HOST} and the
	     default domain as ${MAIL_DOMAIN}, leave DKIM key generation on, and leave
	     the TLS certificate request on. The wizard shows the password for the
	     permanent admin@${MAIL_DOMAIN} account exactly once: save it then.
	  3. Restart so the mail listeners come up:
	       cd $APP_DIR && docker compose restart
	     Then confirm 25, 465 and 993 answer:
	       ss -ltn | grep -E ':(25|465|993) '
	  4. Close the bootstrap door. Delete the STALWART_RECOVERY_ADMIN line from
	     $APP_DIR/.env, then
	       cd $APP_DIR && docker compose up -d --force-recreate
	     and confirm an unauthenticated admin call is still refused:
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/api/account
	     That must print 401.
	  5. Publish DNS for ${MAIL_DOMAIN}: the MX record, the SPF record, the DKIM
	     record the wizard generated and a DMARC record. The admin UI lists the
	     whole set on the domain's page. Nothing you send authenticates until
	     they are live, and propagation is measured in hours.
	  6. In the admin UI change the ACME provider's challenge type to HTTP-01
	     and set the certificate subject alternative names to ${DOMAIN_HOST}
	     alone, then confirm the certificate on the mail ports is a real one:
	       openssl s_client -connect ${DOMAIN_HOST}:465 -servername ${DOMAIN_HOST} -verify_return_error </dev/null 2>&1 | grep 'Verify return code'
	  7. Run this backup again after the wizard. The archive written above holds
	     an empty server. It also sits on the same disk as the data, which is not
	     a backup: copy it off the box tonight.

DONE
