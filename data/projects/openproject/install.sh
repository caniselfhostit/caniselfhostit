#!/usr/bin/env bash
# OpenProject · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=projects.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.openproject.org/docs/installation-and-operations/installation/docker/
#   https://www.openproject.org/docs/installation-and-operations/installation/docker-compose/
#   https://www.openproject.org/docs/installation-and-operations/configuration/
#   https://www.openproject.org/docs/installation-and-operations/operation/monitoring/
#
# Three secrets are generated here, on this machine: SECRET_KEY_BASE, the
# password the seeder puts on the admin account, and the PostgreSQL password.
# All three go into /srv/openproject/.env with mode 600 and none is printed.
#
# DOMAIN_HOST is also OPENPROJECT_HOST__NAME, the name OpenProject builds every
# link and form action from. Upstream warns that a container reached on a name
# it was not told about is open to Host header injection.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/openproject}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. projects.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; upstream's floor for a single-server install is 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 20 ] || die "only ${avail_gb} GB free on /srv; upstream's floor is 20 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/assets"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64 for all three: one value travels inside a database
# connection string, and OpenProject parses environment values as YAML, where
# base64 punctuation is a hazard. Read the admin password later with
#   sudo grep OPENPROJECT_SEED_ADMIN_USER_PASSWORD /srv/openproject/.env
# SECRET_KEY_BASE has to stay the same across restarts: it derives the key for
# the encrypted columns in the database, so a dump restored without this file
# is a dump nobody can read.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		OPENPROJECT_HOST__NAME=${DOMAIN_HOST}
		OPENPROJECT_HTTPS=true
		SECRET_KEY_BASE=$(openssl rand -hex 64)
		OPENPROJECT_SEED_ADMIN_USER_PASSWORD=$(openssl rand -hex 24)
		DB_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-openproject"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8116 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8116 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The container runs every database migration and then the seeder before the
# Apache inside it exists, so the first boot takes minutes and Caddy answers
# 502 for all of them. Ten minutes of patience is budgeted below.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/health_checks/default (this takes minutes on a first boot)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/health_checks/default" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/health_checks/default answered ${code:-nothing}. Check: docker compose logs --tail 60 openproject"

curl -sS "https://${DOMAIN_HOST}/health_checks/default" | grep -q 'PASSED' \
	|| die "the health endpoint answered 200 without PASSED. Check: docker compose logs --tail 60 openproject"

curl -sS "https://${DOMAIN_HOST}/login" | grep -q '<h1>Sign in</h1>' \
	|| die "the login page did not contain the Sign in heading. A warning page here means SERVER_NAME reached the container."

# The seeded admin must not answer to the password upstream's docs print. The
# seeder read OPENPROJECT_SEED_ADMIN_USER_PASSWORD from .env before it ran, so
# this should already be false; if it is not, the install is not safe to leave.
default_works="$(docker compose exec -T openproject bundle exec rails runner 'puts User.find_by(login: "admin").check_password?("admin").to_s' | tr -d '\r' | tail -1)"
[ "$default_works" = "false" ] || die "the admin account still answers to the password upstream documents. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U openproject -d openproject -x -O | gzip > "$APP_DIR/backups/openproject-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/openproject-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env assets -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/openproject-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	OpenProject is answering at https://${DOMAIN_HOST}/login

	  1. Sign in as admin. Your generated password is in $APP_DIR/.env,
	     mode 600. Read it with
	       sudo grep OPENPROJECT_SEED_ADMIN_USER_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here, and
	     the account no longer answers to the password upstream documents.
	  2. OpenProject will make you set your own password on that first
	     sign-in. That screen is the install working, not failing. The
	     seeded account carries admin@example.net; change it in your profile.
	  3. No mail is configured. Every notification OpenProject would have
	     emailed stays inside the web interface until you set up SMTP.
	  4. First backup written to $APP_DIR/backups: a database dump and a
	     file archive with the attachments, compose.yml, .env and the Caddy
	     site block. They are on the same disk as the data, which is not a
	     backup. Copy them somewhere else tonight, and keep .env with them:
	     SECRET_KEY_BASE is what decrypts the encrypted columns in the dump.

DONE
