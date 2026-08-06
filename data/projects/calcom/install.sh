#!/usr/bin/env bash
# Cal.com · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=cal.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation, read at tag v6.2.0
# of https://github.com/calcom/cal.diy :
#   docs/self-hosting/docker.mdx
#   .env.example
#   Dockerfile
#   scripts/start.sh
#
# Three secrets are generated here, on this machine: the PostgreSQL password,
# the NextAuth session secret, and the encryption key over saved calendar
# credentials. All three go into /srv/calcom/.env with mode 600 and none is ever
# printed. CALENDSO_ENCRYPTION_KEY cannot be rotated: every calendar connection
# added later is encrypted with it.
#
# This script stops twice for you. Once to put your mail relay credentials into
# .env, because Cal.com mails the confirmation to whoever booked. Once to create
# the first administrator account in a browser, which only a human can do.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/calcom}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
CALCOM_TAG="v6.2.0"
CALCOM_ARM_PIN="v6.2.0-arm@sha256:4b0fa72eec13bd3ddb608a6d13f05bf0ebc136e73832abfe1a8ec145db9e4651"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. cal.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 4096 ] || die "only ${avail_mb} MB of RAM available; a Next.js server plus PostgreSQL wants 4096 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 15 ] || die "only ${avail_gb} GB free on /srv; the image alone is 1.5 GB compressed"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# Upstream publishes no multi-architecture manifest: the arm64 build of the same
# release is a separate tag with an -arm suffix.
if [ "$(dpkg --print-architecture)" = "arm64" ]; then
	sed "s|:${CALCOM_TAG}@sha256:[a-f0-9]*|:${CALCOM_ARM_PIN}|" "$APP_DIR/compose.yml" > "$APP_DIR/compose.arm"
	mv "$APP_DIR/compose.arm" "$APP_DIR/compose.yml"
fi

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Base64 for the two Cal.com values because that is what upstream documents, hex
# for the database password because it also travels inside a connection string.
# Read them later with
#   grep -E 'POSTGRES_PASSWORD|NEXTAUTH_SECRET|CALENDSO_ENCRYPTION_KEY' /srv/calcom/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXT_PUBLIC_WEBAPP_URL=https://${DOMAIN_HOST}
		NEXT_PUBLIC_WEBSITE_URL=https://${DOMAIN_HOST}
		CALCOM_TELEMETRY_DISABLED=1
		POSTGRES_PASSWORD=$(openssl rand -hex 32)
		NEXTAUTH_SECRET=$(openssl rand -base64 32)
		CALENDSO_ENCRYPTION_KEY=$(openssl rand -base64 24)
		EMAIL_FROM=CHANGE_ME
		EMAIL_FROM_NAME=CHANGE_ME
		EMAIL_SERVER_HOST=CHANGE_ME
		EMAIL_SERVER_PORT=587
		EMAIL_SERVER_USER=CHANGE_ME
		EMAIL_SERVER_PASSWORD=CHANGE_ME
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

# --- 4. The mail relay, which only you can supply ----------------------------

unset_lines="$(grep -c CHANGE_ME "$APP_DIR/.env" || true)"
if [ "$unset_lines" != "0" ]; then
	cat >&2 <<-STOPMAIL

		STOP. Cal.com mails the confirmation to whoever booked, so an install with
		no outbound relay tells nobody anything.

		Open $APP_DIR/.env, replace every CHANGE_ME with the matching value from
		your mail relay, correct EMAIL_SERVER_PORT if it is not 587, then run
		this script again.

	STOPMAIL
	exit 1
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 5. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-calcom"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 6. Ports: two open, and neither 8094 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8094 and 5432 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 7. Start it -------------------------------------------------------------
#
# A fresh container rewrites every compiled-in copy of the built URL, waits for
# PostgreSQL, applies the Prisma migrations and seeds the app store before
# Next.js listens on anything. Minutes, not seconds.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/auth/setup?step=1 (this takes minutes)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/auth/setup?step=1" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/auth/setup answered ${code:-nothing}. Check: docker compose logs --tail 60 calcom"

curl -sS "https://${DOMAIN_HOST}/auth/setup?step=1" | grep -q '<title>Setup | Cal.com</title>' \
	|| die "the setup page answered 200 without the expected title. Check: docker compose logs --tail 60 calcom"

# Registration is open on a fresh install. Step 9 closes it and proves it.
open_signup="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/signup" || true)"
[ "$open_signup" = "200" ] || die "/signup answered ${open_signup}, not 200. The app is not fully up."

# --- 8. The first administrator account, which only a human can create -------

cat <<-STOPSETUP

	STOP. Open https://${DOMAIN_HOST}/auth/setup?step=1 in a browser now.

	The first screen is a wizard headed "Administrator user" with the line
	"Let's create the first administrator user." under it. Create that account.
	The password rule is upstream's: at least 15 characters, one number, and
	both cases. Step 2 asks you to pick a licence; the free AGPLv3 option is the
	one this install runs under.

STOPSETUP
printf 'Press Enter once the account exists. '
read -r _

# --- 9. Close registration, and prove it is closed ---------------------------

if ! grep -q '^NEXT_PUBLIC_DISABLE_SIGNUP=' "$APP_DIR/.env"; then
	printf 'NEXT_PUBLIC_DISABLE_SIGNUP=true\n' >> "$APP_DIR/.env"
fi
docker compose up -d --force-recreate calcom

echo "==> waiting for the recreated container (it rewrites the built URL again)"
for _ in $(seq 1 60); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/auth/login" || true)"
	[ "$code" = "200" ] && break
	sleep 15
done
[ "${code:-}" = "200" ] || die "/auth/login answered ${code:-nothing} after the restart"

signup="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "https://${DOMAIN_HOST}/signup" || true)"
case "$signup" in
	3*auth/error*) : ;;
	*) die "/signup returned '${signup}' rather than a redirect to /auth/error. Registration is still open." ;;
esac

# --- 10. The first backup, before day one ends -------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U calcom -d calcom | gzip > "$APP_DIR/backups/calcom-db-${STAMP}.sql.gz"
sudo tar -C "$APP_DIR" -czf "$APP_DIR/backups/calcom-config-${STAMP}.tar.gz" compose.yml Caddyfile .env
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/calcom-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Cal.com is answering at https://${DOMAIN_HOST}

	  1. Registration is closed. The "Create an account" link is still drawn on
	     the login page, because that link is compiled into the image, but the
	     page behind it redirects to /auth/error. Only your account exists.
	  2. Your three secrets are in $APP_DIR/.env, mode 600. None was printed
	     here. CALENDSO_ENCRYPTION_KEY is the one you cannot replace: every
	     calendar connection you add later is encrypted with it.
	  3. First backup written to $APP_DIR/backups: a database dump and a config
	     archive. They are on the same disk as the data, which is not a backup.
	     Copy them somewhere else tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/calcom/
	     Restore needs both. A dump restored beside a newly generated
	     encryption key is a table of unreadable tokens.
	  4. Google and Outlook calendar sync are not configured. They need an
	     OAuth client you register in your own Google Cloud or Azure tenant.

DONE
