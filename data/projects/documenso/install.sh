#!/usr/bin/env bash
# Documenso · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=sign.example.com ADMIN_EMAIL=you@example.com \
#     RELAY_HOST=smtp.example.net RELAY_PORT=587 RELAY_USER=you@example.com ./install.sh
#
# It prompts once, silently, for the relay password. That value is never echoed
# and never reaches your shell history.
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.documenso.com/docs/self-hosting/getting-started/requirements
#   https://docs.documenso.com/docs/self-hosting/deployment/docker-compose
#   https://docs.documenso.com/docs/self-hosting/configuration/signing-certificate/local
#   https://caddyserver.com/docs/automatic-https
#
# Five secrets are generated here, on this machine: NEXTAUTH_SECRET, the two
# encryption keys, the PostgreSQL password and the passphrase on the signing
# certificate. All five go into /srv/documenso/.env at mode 600 and none of them
# is ever printed. Do not change the encryption keys later: the encrypted
# columns in the database are read back with them.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/documenso}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
RELAY_HOST="${RELAY_HOST:-}"
RELAY_PORT="${RELAY_PORT:-587}"
RELAY_USER="${RELAY_USER:-$ADMIN_EMAIL}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. sign.example.com"
[ -n "$ADMIN_EMAIL" ] || die "set ADMIN_EMAIL to the address the first account will use"
[ -n "$RELAY_HOST" ]  || die "set RELAY_HOST to an SMTP relay you already have. Nobody can sign in until a confirmation mail is delivered."
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; Next.js plus PostgreSQL wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Five generated secrets, plus the relay password you already own -------
#
# Hex rather than base64: the database password rides inside a PostgreSQL
# connection string, where + and / would have to be escaped. Read any of them
# later with
#   sudo grep NEXTAUTH_SECRET /srv/documenso/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		NEXT_PUBLIC_WEBAPP_URL=https://${DOMAIN_HOST}
		NEXT_PRIVATE_INTERNAL_WEBAPP_URL=http://localhost:3000
		NEXTAUTH_SECRET=$(openssl rand -hex 32)
		NEXT_PRIVATE_ENCRYPTION_KEY=$(openssl rand -hex 32)
		NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH=/opt/documenso/cert.p12
		NEXT_PRIVATE_SIGNING_PASSPHRASE=$(openssl rand -hex 24)
		NEXT_PRIVATE_SMTP_HOST=${RELAY_HOST}
		NEXT_PRIVATE_SMTP_PORT=${RELAY_PORT}
		NEXT_PRIVATE_SMTP_USERNAME=${RELAY_USER}
		NEXT_PRIVATE_SMTP_FROM_NAME=Documenso
		NEXT_PRIVATE_SMTP_FROM_ADDRESS=${ADMIN_EMAIL}
		NEXT_PUBLIC_DISABLE_SIGNUP=false
		DOCUMENSO_DISABLE_TELEMETRY=true
	ENVFILE
	printf 'NEXT_PRIVATE_SMTP_PASSWORD=' >> "$APP_DIR/.env"
	printf 'Relay password for %s (input is hidden): ' "$RELAY_USER" > /dev/tty
	read -rs relay_value < /dev/tty
	printf '\n' > /dev/tty
	printf '%s\n' "$relay_value" >> "$APP_DIR/.env"
	unset relay_value
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

awk -F= '/^NEXT_PRIVATE_SMTP_PASSWORD/ {print "relay password recorded, length " length($2)}' "$APP_DIR/.env"

# --- 4. The signing certificate ----------------------------------------------
#
# Documenso ships none, and without one it starts, serves pages and fails every
# signature. Self-signed, ten years: one that expires quietly turns into failed
# signings nobody diagnoses. It proves a completed document has not changed
# since signing. It will not make Adobe Acrobat show a green check; only a
# certificate from an authority on Adobe's trust list does that.

if [ ! -f "$APP_DIR/cert.p12" ]; then
	umask 077
	openssl genrsa -out "$APP_DIR/private.key" 2048
	openssl req -new -x509 -key "$APP_DIR/private.key" -out "$APP_DIR/certificate.crt" -days 3650 -subj "/CN=${DOMAIN_HOST}/O=${DOMAIN_HOST}"
	CERT_PASS="$(sed -n 's/^NEXT_PRIVATE_SIGNING_PASSPHRASE=//p' "$APP_DIR/.env")" \
		openssl pkcs12 -export -out "$APP_DIR/cert.p12" -inkey "$APP_DIR/private.key" -in "$APP_DIR/certificate.crt" -password env:CERT_PASS
	rm -f "$APP_DIR/private.key" "$APP_DIR/certificate.crt"
	umask 022
fi
sudo chown 1001:1001 "$APP_DIR/cert.p12"
sudo chmod 400 "$APP_DIR/cert.p12"
[ -s "$APP_DIR/cert.p12" ] || die "the signing certificate is empty. Remove it and run this again."

cd "$APP_DIR"
docker compose config >/dev/null

# --- 5. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-documenso"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 6. Ports: two open, and neither 8142 nor 5432 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8142, 5432 and every mail port stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 7. Start it and prove it works ------------------------------------------
#
# The container migrates the database on the way up, so the first start is slow.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/health (migrations, then Caddy's certificate)"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/health" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/health answered ${code:-nothing}. Check: docker compose logs --tail 40 documenso"

curl -sS "https://${DOMAIN_HOST}/api/health" | grep -q '"certificate":{"status":"ok"}' \
	|| die "health reports the signing certificate is not usable. Check ownership: ls -l $APP_DIR/cert.p12"

curl -sS "https://${DOMAIN_HOST}/signin" | grep -q 'Sign in to your account' \
	|| die "the sign-in page did not contain 'Sign in to your account'. Check: docker compose logs --tail 40 documenso"

signup_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/signup" || true)"
[ "$signup_code" = "200" ] || die "/signup answered ${signup_code}, so the first account cannot be created. Check the logs."

# --- 8. The first account, then close registration ---------------------------

cat <<-SETUP

	Open https://${DOMAIN_HOST}/signup now, create the first account with
	${ADMIN_EMAIL}, click the link in the confirmation email, and sign in.
	Nobody can sign in until that mail is delivered, and until you do this,
	whoever finds this hostname can create the first account instead.

SETUP
printf 'Press Return once you are signed in. '
read -r _

sed -i 's/^NEXT_PUBLIC_DISABLE_SIGNUP=false$/NEXT_PUBLIC_DISABLE_SIGNUP=true/' "$APP_DIR/.env"
docker compose up -d --force-recreate documenso
sleep 20
signup_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/signup" || true)"
echo "==> /signup now answers ${signup_code}"
[ "$signup_code" = "302" ] || die "/signup answers ${signup_code}, not 302, so registration is still open."

# --- 9. The first backup, before day one ends --------------------------------
#
# The dump is the documents as well as the accounts: with the default upload
# transport every PDF is a row in that database.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U documenso -d documenso | gzip > "$APP_DIR/backups/documenso-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/documenso-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env cert.p12 -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/documenso-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/documenso-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	Documenso is answering at https://${DOMAIN_HOST}/

	  1. Registration is closed. Reopen it by setting NEXT_PUBLIC_DISABLE_SIGNUP
	     to false in $APP_DIR/.env and running
	       cd $APP_DIR && docker compose up -d --force-recreate documenso
	  2. The signature on a completed document is made with the self-signed
	     certificate in $APP_DIR/cert.p12. It proves the document has not been
	     altered since signing. Adobe Acrobat will still say the signature cannot
	     be verified, because that certificate is not on Adobe's trust list.
	  3. The two backup files travel together. The dump holds the documents; the
	     archive holds .env, whose encryption keys are what the encrypted columns
	     are read back with, and cert.p12, the identity the signatures were made
	     with. One without the other is not a restore.
	  4. Both are on the same disk as the data, which is not a backup. Copy them
	     somewhere else tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/documenso/

DONE
