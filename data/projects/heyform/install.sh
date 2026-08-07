#!/usr/bin/env bash
# HeyForm · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=forms.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.heyform.net/open-source/self-hosting
#   https://github.com/heyform/heyform/blob/v3.0.0/Dockerfile
#   https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/environments/index.ts
#   https://github.com/heyform/heyform/blob/v3.0.0/packages/server/src/controller/health.controller.ts
#   https://github.com/heyform/heyform/blob/v3.0.0/docs/invite-only-registration.md
#
# Four secrets are generated here, on this machine: the session key, the form
# token key, the MongoDB password and the Valkey password. All four go into
# /srv/heyform/.env with mode 600 and none of them is ever printed.
#
# DOMAIN_HOST becomes APP_HOMEPAGE_URL, which every form link is built from, and
# which HeyForm also derives its cookie domain and CORS allowlist from. Choose it
# once: changing it later breaks links you have already sent out.
#
# This script leaves account registration OPEN, because only a human with a
# browser can create the first account. The closing summary gives you the two
# commands that close it. Run them the same hour.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/heyform}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. forms.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; HeyForm plus MongoDB and Valkey wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

# MongoDB 7 exits during start-up on an x86 CPU without AVX, and no setting
# changes that, so it is a preflight failure rather than a runtime surprise.
if [ "$(dpkg --print-architecture)" = "amd64" ] && ! grep -q -w avx /proc/cpuinfo; then
	die "this CPU has no AVX, which MongoDB 7 requires on amd64"
fi

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/uploads"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the four secrets, on the server -----------------------------
#
# Hex for all four: two of them travel inside connection strings and neither
# wants escaping. Read them later with
#   sudo grep -E 'SESSION_KEY|FORM_ENCRYPTION_KEY|MONGO_PASSWORD|REDIS_PASSWORD' /srv/heyform/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_HOMEPAGE_URL=https://${DOMAIN_HOST}
		SESSION_KEY=$(openssl rand -hex 32)
		FORM_ENCRYPTION_KEY=$(openssl rand -hex 32)
		MONGO_PASSWORD=$(openssl rand -hex 32)
		REDIS_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-heyform"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8170, 27017 and 6379 are none of them -----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8170, 27017 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# MongoDB creates its root user the first time it initialises an empty volume,
# and HeyForm waits for both databases to report healthy before it starts.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health/ready"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health/ready" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health/ready answered ${code:-nothing}. Check: docker compose logs --tail 40 heyform"

# The readiness body names the two databases separately, which is the only way
# to tell a container that never started from one that failed authentication.
curl -sS "https://${DOMAIN_HOST}/health/ready" | grep -q '"checks":{"mongo":"up","redis":"up"}' \
	|| die "/health/ready answered 200 without both databases up. Check: docker compose logs --tail 40 heyform"

# The application answered through Caddy, not only the health route.
curl -sS "https://${DOMAIN_HOST}/login" | grep -q '<title>HeyForm</title>' \
	|| die "https://${DOMAIN_HOST}/login did not render the HeyForm page. Check the Caddy site block."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mongo sh -c 'mongodump --quiet --archive --gzip --db=heyform -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' > "$APP_DIR/backups/heyform-db-${STAMP}.archive.gz"
sudo tar -czf "$APP_DIR/backups/heyform-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/heyform-db-${STAMP}.archive.gz" ] || die "the database dump is empty"

cat <<-DONE

	HeyForm is answering at https://${DOMAIN_HOST}/login

	  1. Registration is OPEN right now, to anyone who finds the hostname.
	     Create your account at https://${DOMAIN_HOST}/sign-up with a real
	     email address (disposable domains are refused, and no confirmation
	     mail arrives because this install has no mail server). Then close
	     registration and check that it closed:

	       cd $APP_DIR
	       echo 'APP_DISABLE_REGISTRATION=true' >> $APP_DIR/.env
	       docker compose up -d --force-recreate heyform
	       sleep 20
	       curl -sS https://${DOMAIN_HOST}/api/config | grep -o '"appDisableRegistration":true'

	     That grep has to print the line, and the sign-in page has to lose its
	     "create an account" link. Do this the same hour, not tomorrow.
	  2. Your four secrets are in $APP_DIR/.env, mode 600. None was printed
	     here. Read them yourself with
	       sudo grep -E 'SESSION_KEY|FORM_ENCRYPTION_KEY' $APP_DIR/.env
	  3. First backup written to $APP_DIR/backups: a MongoDB dump and a config
	     archive that also carries $APP_DIR/uploads and the live Caddy config.
	     They are on the same disk as the data, which is not a backup. Copy
	     them somewhere else tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/heyform/
	  4. No mail server is configured, so response notifications and password
	     reset do not work. That one account is your whole way back in.

DONE
