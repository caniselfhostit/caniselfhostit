#!/usr/bin/env bash
# Formbricks · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=surveys.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://formbricks.com/docs/self-hosting/setup/docker
#   https://formbricks.com/docs/self-hosting/configuration/environment-variables
#   https://formbricks.com/docs/self-hosting/auth-behavior
#   https://github.com/formbricks/formbricks/blob/5.3.0/charts/formbricks/values.yaml
#
# Six secrets are generated here, on this machine: the PostgreSQL password and
# the five keys the application requires. All six go into /srv/formbricks/.env
# with mode 600 and none is ever printed. ENCRYPTION_KEY is the one that
# matters most: upstream uses it for two-factor secrets, single-use survey
# links and audit-log hashing, so a database restored without that file is a
# database nobody can fully read.
#
# DOMAIN_HOST is also WEBAPP_URL, the front of every survey link you send.
# Choose it once. Changing it later breaks links already in other inboxes.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/formbricks}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
TAG="5.3.0"
RAW="https://raw.githubusercontent.com/formbricks/formbricks/${TAG}/docker/cube"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. surveys.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; five services want 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; this install wants 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out, and verify the two Cube config files --------------
#
# Cube reads a config file and a data model that upstream ships in their
# repository rather than in their image. Both are fetched at the pinned tag and
# checked against digests read on 2026-08-06 before anything mounts them.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/cube" "$APP_DIR/cube/schema"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/redis"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

cd "$APP_DIR/cube"
for f in cube.js schema/FeedbackRecords.js; do
	curl -fsSL -o "$f" "${RAW}/${f}"
done
cat > SHA256SUMS <<-'SUMS'
	723eea0f581200a686f854ff47b38f2e92bbfe5d802338049afaa061f154a335  cube.js
	c3322a3739ee1cc57224139f502395a20dcbe4dd71e331be41d687ffdfe140f8  schema/FeedbackRecords.js
SUMS
sha256sum -c SHA256SUMS || die "a Cube config file does not match its recorded digest. Stop and investigate."

# --- 3. Generate the six secrets, on the server ------------------------------
#
# Hex, because upstream caps NEXTAUTH_SECRET, ENCRYPTION_KEY and CRON_SECRET at
# 32 bytes. Read them later with
#   sudo grep ENCRYPTION_KEY /srv/formbricks/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		WEBAPP_URL=https://${DOMAIN_HOST}
		NEXTAUTH_URL=https://${DOMAIN_HOST}
		DB_PASSWORD=$(openssl rand -hex 32)
		NEXTAUTH_SECRET=$(openssl rand -hex 32)
		ENCRYPTION_KEY=$(openssl rand -hex 32)
		CRON_SECRET=$(openssl rand -hex 32)
		HUB_API_KEY=$(openssl rand -hex 32)
		CUBEJS_API_SECRET=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-formbricks"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and none of the five app ports is one of them -------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8110, 5432, 6379, 8080 and 4000 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The two migration jobs run and exit first, then Cube has to report healthy
# before the web container is allowed to start. On a cold pull that chain takes
# several minutes, which is what the loop below is for.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/health answered ${code:-nothing}. Check: docker compose logs --tail 40 formbricks cube hub-migrate"

curl -sS "https://${DOMAIN_HOST}/health" | grep -q '"status":"ok"' \
	|| die "/health answered 200 without status ok. Check: docker compose logs --tail 40 formbricks"

# A fresh instance sends the root to the setup wizard. Both of these are the
# same assert from two directions: the redirect target, and the heading.
landing="$(curl -sSL -o /dev/null -w '%{url_effective}' "https://${DOMAIN_HOST}/" || true)"
[ "$landing" = "https://${DOMAIN_HOST}/setup/intro" ] \
	|| die "https://${DOMAIN_HOST}/ landed on ${landing}, not the setup wizard. Stop and investigate."
curl -sSL "https://${DOMAIN_HOST}/" | grep -q 'Welcome to Formbricks' \
	|| die "the first screen does not carry 'Welcome to Formbricks'. Check: docker compose logs --tail 40 formbricks"

docker compose ps -a

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U formbricks -d formbricks | gzip > "$APP_DIR/backups/formbricks-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/formbricks-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env cube -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/formbricks-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/formbricks-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Formbricks is answering at https://${DOMAIN_HOST}/health

	  1. Open https://${DOMAIN_HOST} now. The first screen says
	     "Welcome to Formbricks!" with a Get started button. Create your
	     administrator account and organization there. That is the only moment
	     it can be made: signup stays closed on self-hosted instances, and
	     afterwards only an owner or admin can invite anyone.
	  2. There is no SMTP server here, so there is no password-reset mail.
	     Put that email and password in your password manager first.
	  3. Once the account exists, confirm the door shut behind you:
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/setup/intro
	     It should print 404. The setup pages answer only while the user table
	     is empty.
	  4. Your six secrets are in $APP_DIR/.env, mode 600, and none was printed
	     here. ENCRYPTION_KEY is the one to keep: a database dump restored
	     without it comes back undecryptable.
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy both somewhere else tonight, and keep them together.

DONE
