#!/usr/bin/env bash
# Typebot · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=typebot.example.com \
#   ADMIN_EMAIL=you@example.com \
#   SMTP_FROM=notifications@example.com \
#   SMTP_HOST=smtp.example.com SMTP_USERNAME=apikey SMTP_PASSWORD=... ./install.sh
#
# SMTP_PASSWORD is read from the environment and never written to your terminal.
# Start that command line with a space if your shell records history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.typebot.com/self-hosting/deploy/docker
#   https://docs.typebot.com/self-hosting/configuration
#
# Typebot is two applications. The builder answers on DOMAIN_HOST and the viewer
# on bot.DOMAIN_HOST; both are Next.js servers that own the root path, so both
# names need an A record on this box before you run this.
#
# Two secrets are generated here, on this machine: the PostgreSQL password and
# ENCRYPTION_SECRET. Both go into /srv/typebot/.env with mode 600, and neither
# is ever printed.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/typebot}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
SMTP_FROM="${SMTP_FROM:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_SECURE="${SMTP_SECURE:-false}"
SMTP_USERNAME="${SMTP_USERNAME:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the builder hostname you pointed at this server, e.g. typebot.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL; it is the only address allowed to create an account on this instance"
[ -n "$SMTP_FROM" ] || die "set SMTP_FROM; without it Typebot registers no sign-in method at all"
[ -n "$SMTP_HOST" ] || die "set SMTP_HOST; sign-in codes arrive by mail and there is no other way in"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; two Next.js servers plus PostgreSQL want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 15 ] || die "only ${avail_gb} GB free on /srv; the two application images want 15 GB"

for host in "$DOMAIN_HOST" "bot.${DOMAIN_HOST}"; do
	resolved="$(getent hosts "$host" | awk '{print $1; exit}' || true)"
	[ -n "$resolved" ] || die "$host does not resolve yet. Add the A record, wait a minute, run this again."
done

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Upstream documents `openssl rand -base64 24` for ENCRYPTION_SECRET and its
# schema rejects anything that is not exactly 32 characters, which is what 24
# random bytes of base64 come to. The database password is hex, so it needs no
# escaping inside a connection string. Read them later with
#   sudo grep -E 'POSTGRES_PASSWORD|ENCRYPTION_SECRET' /srv/typebot/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXTAUTH_URL=https://${DOMAIN_HOST}
		NEXT_PUBLIC_VIEWER_URL=https://bot.${DOMAIN_HOST}
		NODE_OPTIONS=--no-node-snapshot
		DISABLE_SIGNUP=true
		DEFAULT_WORKSPACE_PLAN=UNLIMITED
		ENCRYPTION_SECRET=$(openssl rand -base64 24)
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		ADMIN_EMAIL=${ADMIN_EMAIL}
		NEXT_PUBLIC_SMTP_FROM=${SMTP_FROM}
		SMTP_HOST=${SMTP_HOST}
		SMTP_PORT=${SMTP_PORT}
		SMTP_SECURE=${SMTP_SECURE}
		SMTP_USERNAME=${SMTP_USERNAME}
		SMTP_PASSWORD=${SMTP_PASSWORD}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site blocks, on the host ---------------------------------------
#
# Two blocks, one per application. The template carries <DOMAIN> twice; the sed
# below substitutes the live hostname, and the archive in step 7 keeps that
# substituted copy rather than the template.

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-typebot"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8177, 8977 nor 5432 is one of them ------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8177, 8977 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The builder applies the Prisma migrations before it listens, and the viewer
# waits for the builder to report healthy, so the first boot takes minutes.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/auth/providers"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/auth/providers" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "the builder answered ${code:-nothing}. Check: docker compose logs --tail 60 builder"

# The email sign-in provider only registers when NEXT_PUBLIC_SMTP_FROM is set.
providers="$(curl -sS "https://${DOMAIN_HOST}/api/auth/providers" || true)"
case "$providers" in
	*nodemailer*) : ;;
	*) die "the builder is up but registered no email sign-in provider. Check NEXT_PUBLIC_SMTP_FROM in $APP_DIR/.env" ;;
esac

viewer="$(curl -sS "https://bot.${DOMAIN_HOST}/api/healthz" || true)"
case "$viewer" in
	*'"status":"ok"'*) : ;;
	*) die "https://bot.${DOMAIN_HOST}/api/healthz answered ${viewer:-nothing}. Check: docker compose logs --tail 40 viewer" ;;
esac

# The viewer API must refuse a call with no bearer token.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://bot.${DOMAIN_HOST}/api/typebots" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated viewer API call returned ${unauth}, not 401. Stop and investigate."

# Registration is closed from the first boot; ADMIN_EMAIL is the one way in.
grep -q '^DISABLE_SIGNUP=true$' "$APP_DIR/.env" || die "DISABLE_SIGNUP is not true in $APP_DIR/.env"

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U typebot -d typebot | gzip > "$APP_DIR/backups/typebot-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/typebot-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/typebot-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Typebot is answering at https://${DOMAIN_HOST}/signin

	  1. Sign in at https://${DOMAIN_HOST}/signin with ${ADMIN_EMAIL}. Typebot
	     mails you a six-digit code; that code arriving is the only proof your
	     relay works. If it does not arrive, read
	       docker compose logs --tail 60 builder
	     and check the spam folder before suspecting the install.
	  2. Registration is closed already. DISABLE_SIGNUP is true from the first
	     boot and upstream's sign-in callback lets exactly one address past it,
	     the one in ADMIN_EMAIL, so there is nothing to close later.
	  3. Published bots answer on https://bot.${DOMAIN_HOST}, a different name
	     from the builder because each is a Next.js server owning the root path.
	     That is the address that goes into the links and embeds you hand out.
	  4. Your two secrets are in $APP_DIR/.env, mode 600, and were not printed
	     here. ENCRYPTION_SECRET is what decrypts the provider keys stored in
	     the database, so back the .env up with the dump, not apart from it.
	  5. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight.

DONE
