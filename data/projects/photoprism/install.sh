#!/usr/bin/env bash
# PhotoPrism · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=photos.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://docs.photoprism.app/getting-started/docker-compose/
#   https://docs.photoprism.app/getting-started/config-options/
#   https://docs.photoprism.app/getting-started/proxies/traefik/
#   https://www.photoprism.app/oss/faq
#
# The image is the "ce" build, which upstream describes as the Community Edition
# distributed under the AGPL, pinned by tag and digest.
#
# Three secrets are generated here, on this machine: the initial admin password,
# the photoprism database user's password and the MariaDB root password. All
# three go into /srv/photoprism/.env with mode 600 and none is ever printed.
#
# DOMAIN_HOST becomes PHOTOPRISM_SITE_URL, the address PhotoPrism writes into
# every link and share it generates.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/photoprism}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. photos.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 3072 ] || die "only ${avail_mb} MB available; upstream's floor is 3 GB physical, which shows as less than 3072 MB available, so plan on a 4 GB machine"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB, and a photo library wants more"

swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"
[ "$swap_mb" -ge 1 ] || echo "install.sh: no swap configured. Upstream asks for 4 GB; the indexer spikes on large files."

uid="$(id -u)"
case "$uid" in
	0|33|5[0-9]|6[0-9]|7[0-9]|8[0-9]|9[0-9]|5[0-9][0-9]|600|9[0-9][0-9]|1[01][0-9][0-9]|12[0-4][0-9]|1250|20[0-9][0-9]|2100) ;;
	*) die "uid ${uid} is outside the ranges upstream supports for PHOTOPRISM_UID (0, 33, 50-99, 500-600, 900-1250, 2000-2100)" ;;
esac

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb stays root-owned at 700: the MariaDB image chowns its own data
# directory and refuses one somebody claimed first. originals is the library;
# storage is cache, sidecar YAML and the nightly dump PhotoPrism writes itself.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/originals" "$APP_DIR/storage"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# Hex rather than base64: two travel inside connection strings and the third is
# typed into a browser once. Read the admin password later with
#   sudo grep PHOTOPRISM_ADMIN_PASSWORD /srv/photoprism/.env
# It is only read by PhotoPrism when the superadmin account is created on the
# first start; after that, change it in Settings, then Account.

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		PHOTOPRISM_SITE_URL=https://${DOMAIN_HOST}/
		PHOTOPRISM_ADMIN_PASSWORD=$(openssl rand -hex 24)
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	printf 'PHOTOPRISM_UID=%s\nPHOTOPRISM_GID=%s\n' "$(id -u)" "$(id -g)" >> "$APP_DIR/.env"
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-photoprism"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8164 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8164 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start creates the schema and the superadmin account. The image is
# about a gigabyte, so the pull is the slow part.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/api/v1/status"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/status" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/api/v1/status answered ${code:-nothing}. Check: docker compose logs --tail 40 photoprism"

curl -sS "https://${DOMAIN_HOST}/api/v1/status" | grep -q '"status":"operational"' \
	|| die "/api/v1/status answered 200 without status operational. Check: docker compose logs --tail 40 photoprism"

# The API must refuse an unauthenticated call. A 200 here would mean the library
# is set to public and every photograph is visible to anyone who finds the name.
unauth="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/api/v1/photos?count=1" || true)"
[ "$unauth" = "401" ] || die "an unauthenticated API call returned ${unauth}, not 401. Stop and investigate."

curl -sS "https://${DOMAIN_HOST}/" | grep -q '<title>PhotoPrism</title>' \
	|| die "the site root did not serve the PhotoPrism app shell. Check: docker compose logs --tail 40 photoprism"

# --- 7. The first backup, before day one ends --------------------------------
#
# Taken now, with an empty library, so the restore path is proved before there
# is anything to lose. The archive carries .env, the storage tree and the live
# Caddy site block rather than the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T mariadb sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/photoprism-db-${STAMP}.sql.gz"
sudo tar --exclude='storage/cache' -czf "$APP_DIR/backups/photoprism-config-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/photoprism-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/photoprism-config-${STAMP}.tar.gz" ] || die "the config archive is empty"

cat <<-DONE

	PhotoPrism is answering at https://${DOMAIN_HOST}

	  1. Sign in as admin. Read the password once with
	       sudo grep PHOTOPRISM_ADMIN_PASSWORD $APP_DIR/.env
	     and put it in your password manager. It was not printed here. Then
	     change it inside PhotoPrism, in Settings, then Account: editing that
	     line afterwards does nothing, because it is only read when the account
	     is created.
	  2. Put photographs in $APP_DIR/originals, then index them:
	       cd $APP_DIR && docker compose exec -T photoprism photoprism index
	     PhotoPrism does not watch that directory, so nothing appears in the
	     library until an index run has seen it.
	  3. This install organises and searches photographs. It does not develop
	     them: no exposure slider, no masking, no presets. Keep whatever you
	     edit with.
	  4. First backup written to $APP_DIR/backups: a database dump and a config
	     archive holding .env, the storage tree and the live Caddy site block.
	     Neither one contains a photograph. Copy both off the box tonight, and
	     the library with them:
	       scp vps:$APP_DIR/backups/* ~/backups/photoprism/
	       rsync -a vps:$APP_DIR/originals/ ~/backups/photoprism/originals/

DONE
