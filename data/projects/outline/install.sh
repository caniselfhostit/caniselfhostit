#!/usr/bin/env bash
# Outline · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=wiki.example.com \
#   SMTP_HOST=smtp.example.com SMTP_USERNAME=apikey SMTP_PASSWORD=... \
#   SMTP_FROM_EMAIL=wiki@example.com ./install.sh
#
# SMTP_PASSWORD is read from the environment and never written to your terminal.
# Start that command line with a space if your shell records history. If your
# relay wants implicit TLS, add SMTP_PORT=465 SMTP_SECURE=true.
#
# Authored by caniselfhostit from the upstream documentation and source:
#   https://docs.getoutline.com/s/hosting/doc/docker-7pfeLP5a8t
#   https://docs.getoutline.com/s/hosting/doc/smtp-cqCJyZGMIB
#   https://github.com/outline/outline/blob/v1.9.2/.env.sample
#   https://github.com/outline/outline/blob/v1.9.2/Dockerfile
#
# Three secrets are generated here, on this machine: SECRET_KEY, UTILS_SECRET
# and the PostgreSQL password. All three go into /srv/outline/.env with mode 600
# and none is ever printed.
#
# DOMAIN_HOST is also URL, the address inside every sign-in link this instance
# mails and every share link it makes. Choose it once. Changing it later breaks
# links other people are already holding.
#
# This script cannot open a browser, so it stops one step short: the workspace
# is claimed by a human, and the closing summary carries the command that proves
# the claim closed the door behind it.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/outline}"
DOMAIN_HOST="${DOMAIN_HOST:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_SECURE="${SMTP_SECURE:-false}"
SMTP_USERNAME="${SMTP_USERNAME:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM_EMAIL="${SMTP_FROM_EMAIL:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. wiki.example.com"
[ -n "$SMTP_HOST" ] || die "set SMTP_HOST; sign-in links arrive by mail and Outline has no password login"
[ -n "$SMTP_FROM_EMAIL" ] || die "set SMTP_FROM_EMAIL; Outline exits at start-up on a from-address it cannot parse"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; three services want 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}')" || resolved=""
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# postgres and redis stay root-owned at 700: both images chown their own data
# directory on first start. data goes to uid 1001, the non-root user the Outline
# image runs as, or every attachment upload fails while everything else works.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 700 "$APP_DIR/postgres" "$APP_DIR/redis"
sudo install -d -m 750 -o 1001 -g 1001 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on this machine --------------------------
#
# Hex for all three: upstream requires SECRET_KEY to be exactly 64 hexadecimal
# characters, and the database password travels inside a connection string.
# Read them later with
#   sudo grep -E 'SECRET_KEY|UTILS_SECRET|DB_PASSWORD' /srv/outline/.env
#
# SECRET_KEY encrypts stored data. Upstream states that changing it later leaves
# users unable to log in, so .env belongs in every backup beside the dump.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		URL=https://${DOMAIN_HOST}
		SECRET_KEY=$(openssl rand -hex 32)
		UTILS_SECRET=$(openssl rand -hex 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		SMTP_HOST=${SMTP_HOST}
		SMTP_PORT=${SMTP_PORT}
		SMTP_SECURE=${SMTP_SECURE}
		SMTP_USERNAME=${SMTP_USERNAME}
		SMTP_PASSWORD=${SMTP_PASSWORD}
		SMTP_FROM_EMAIL=${SMTP_FROM_EMAIL}
	ENVFILE
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-outline"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8185, 5432 and 6379 are not among them ----------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8185, 5432 and 6379 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# Outline runs its own database migrations on the way up, so the first boot
# takes minutes rather than seconds.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/_health"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/_health")" || code=""
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/_health answered ${code:-nothing}. Check: docker compose logs --tail 60 outline"

health="$(curl -sS "https://${DOMAIN_HOST}/_health")" || health=""
[ "$health" = "OK" ] || die "/_health returned '${health}', not OK. It queries PostgreSQL and Redis before answering."

# An unclaimed installation offers no sign-in providers at all, because the
# email provider only appears once a workspace exists. This is the assert that
# says the create-workspace form below is the real first screen.
cfg="$(curl -sS -H 'content-type: application/json' -d '{}' "https://${DOMAIN_HOST}/api/auth.config")" || cfg=""
printf '==> auth.config: %s\n' "$cfg"
case "$cfg" in
	*'"providers":[]'*) ;;
	*) die "auth.config did not report an empty provider list. A workspace may already exist on this hostname." ;;
esac

# Nothing in the wiki is readable without a session, before or after the claim.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d '{}' "https://${DOMAIN_HOST}/api/documents.list")" || unauth=""
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T postgres pg_dump -U outline -d outline | gzip > "$APP_DIR/backups/outline-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/outline-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env data -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/outline-db-${STAMP}.sql.gz" ] || die "the database dump is empty"

cat <<-DONE

	Outline is answering at https://${DOMAIN_HOST}

	  1. Open that address now, not later. With no workspace yet, the page is a
	     Create workspace form, and whoever fills it in first becomes the admin
	     of this install. Enter a workspace name, your name and your email.
	  2. Then prove the door shut behind you, from this shell:
	       curl -sS -H 'content-type: application/json' \\
	         -d '{"teamName":"closed","userName":"closed","userEmail":"closed@example.com"}' \\
	         https://${DOMAIN_HOST}/api/installation.create
	     It must print a body containing: Installation already has existing teams
	     Anything else means the workspace was never claimed, and the form is
	     still open to whoever finds this hostname.
	  3. Test the way back in, because there is no password. Sign out, enter
	     your email on the sign-in page, and open the link that arrives. If it
	     never lands, read
	       docker compose logs --tail 60 outline
	     for the SMTP error, then add a passkey under Settings, Security as a
	     second way in that needs no mail.
	  4. Your three secrets are in $APP_DIR/.env, mode 600, and none was printed
	     here. SECRET_KEY encrypts stored data, so back .env up with the
	     database dump rather than separately.
	  5. First backup written to $APP_DIR/backups: a database dump and a file
	     archive carrying attachments, compose.yml, .env and the live Caddyfile.
	     Both are on the same disk as the data, which is not a backup. Copy them
	     off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/outline/

DONE
