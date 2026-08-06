#!/usr/bin/env bash
# Memos · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=notes.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://www.usememos.com/docs/deploy/docker-compose
#   https://www.usememos.com/docs/configuration/environment-variables
#   https://www.usememos.com/docs/configuration/security
#   https://www.usememos.com/docs/getting-started
#   https://github.com/usememos/memos/blob/v0.30.0/docs/configuration-provisioning.md
#
# No secret is generated here and no .env file is written. Memos keeps its own
# session key inside its database, and the only credential a human types is the
# administrator password chosen in a browser after this script finishes.
#
# The one configuration file this script writes turns self-registration off
# before the container has ever started, so there is no window in which a
# stranger can sign themselves up. The very first account still gets through,
# because an instance with zero users takes the setup path rather than the
# registration path. That account is yours to claim: the summary at the end
# gives you the exact URL and the command that proves the window is shut.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/memos}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. notes.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 512 ] || die "only ${avail_mb} MB of RAM available; this install wants 512 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 5 ] || die "only ${avail_gb} GB free on /srv; this install wants 5 GB"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# data belongs to uid 10001, the uid the container re-execs as. config is yours
# and world-readable, because the container user is not the login user and the
# file inside it holds a policy flag rather than a credential.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups"
sudo install -d -m 755 -o "$(id -u)" -g "$(id -g)" "$APP_DIR/config"
sudo install -d -m 750 -o 10001 -g 10001 "$APP_DIR/data"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. The one configuration file, written before the first boot ------------

cat > "$APP_DIR/config/memos-instance-setting-general.json" <<'GENERAL'
{
  "key": "GENERAL",
  "generalSetting": {
    "disallowUserRegistration": true
  }
}
GENERAL
chmod 644 "$APP_DIR/config/memos-instance-setting-general.json"

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-memos"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and 8131 is not one of them --------------------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8131 stays closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/healthz"
for _ in $(seq 1 24); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/healthz" || true)"
	[ "$code" = "200" ] && break
	sleep 5
done
[ "${code:-}" = "200" ] || die "/healthz answered ${code:-nothing}. Check: docker compose logs --tail 40 memos"

body="$(curl -sS "https://${DOMAIN_HOST}/healthz" || true)"
[ "$body" = "Service ready." ] || die "/healthz answered 200 with '${body}' instead of 'Service ready.'. Stop and investigate."

# The pinned release is the one actually answering, and nobody has claimed the
# administrator account yet. Both are expected here; the second is the thing you
# have to go and fix in a browser.
profile="$(curl -sS "https://${DOMAIN_HOST}/api/v1/instance/profile" || true)"
case "$profile" in
	*'"version":"0.30.0"'*) ;;
	*) die "the instance profile did not report version 0.30.0. Got: ${profile}" ;;
esac
case "$profile" in
	*'"needsSetup":true'*) ;;
	*) die "the instance profile did not report needsSetup true, so this server already has an account. Stop and investigate." ;;
esac

# The security assert: self-registration is off before anyone could have used it.
general="$(curl -sS "https://${DOMAIN_HOST}/api/v1/instance/settings/GENERAL" || true)"
case "$general" in
	*'"disallowUserRegistration":true'*) ;;
	*) die "registration is not disabled. The file in ${APP_DIR}/config was not read; check: docker compose logs --tail 40 memos" ;;
esac

# --- 7. The first backup, before day one ends --------------------------------
#
# The database, the photos, the deployment configuration and the live Caddy
# config. One archive, because there is only one thing here to lose.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose stop
sudo tar -czf "$APP_DIR/backups/memos-${STAMP}.tar.gz" -C "$APP_DIR" data config compose.yml -C /etc/caddy Caddyfile
docker compose start
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/memos-${STAMP}.tar.gz" ] || die "the backup archive is empty"

cat <<-DONE

	Memos 0.30.0 is answering at https://${DOMAIN_HOST}/healthz

	  1. Do this first, now, before anything else. Open
	       https://${DOMAIN_HOST}/auth/signup
	     and create your account on the screen headed "Set up your instance".
	     That exact path matters: the sign-in page has no sign-up link, because
	     registration is already off. Until you claim it, the first person to
	     load that path becomes the administrator of this server. Then prove the
	     window is shut:
	       curl -sS https://${DOMAIN_HOST}/api/v1/instance/profile
	     That must no longer contain "needsSetup":true.
	  2. Use a password from your password manager and save it there before you
	     submit the form. It is the only credential this install has, and
	     nothing on this server has a copy of it in plain text.
	  3. Nobody can sign themselves up here. To add a second person, create the
	     account for them from the administrator settings.
	  4. First backup written to $APP_DIR/backups. It is on the same disk as
	     the data, which is not a backup. Copy it somewhere else tonight:
	       scp vps:$APP_DIR/backups/*.tar.gz ~/backups/memos/

DONE
