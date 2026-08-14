#!/usr/bin/env bash
# Lychee · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=photos.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://lycheeorg.dev/docs/getting-started/docker/
#   https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker-compose.yaml
#   https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker/scripts/entrypoint.sh
#   https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker/scripts/01-validate-env.sh
#
# The image is the LycheeOrg project's own FrankenPHP build, pinned by tag and
# digest. Three secrets are generated here, on this machine: the Laravel
# APP_KEY, the lychee database user's password and the MariaDB root password.
# All three go into /srv/lychee/.env with mode 600 and none is ever printed.
#
# Lychee ships no account. Whoever first submits the form this script leaves
# waiting at https://<DOMAIN_HOST>/install/admin becomes the administrator of
# the gallery, so do that immediately: the closing notes carry the step and the
# check that proves the form is shut afterwards.
#
# DOMAIN_HOST is the address every album link and image URL will carry.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/lychee}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. photos.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 2048 ] || die "only ${avail_mb} MB of RAM available; FrankenPHP plus ImageMagick plus MariaDB wants 2048 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB, and a photo library wants more"

# The container's start-up script exits if PUID falls outside this range, and
# these are the values written into .env below.
run_uid="$(id -u)"
run_gid="$(id -g)"
[ "$run_uid" -ge 33 ] && [ "$run_uid" -le 65534 ] || die "your uid is ${run_uid}; the Lychee image accepts PUID 33 to 65534 only. Run this as a normal login user."

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || echo "")"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb stays root-owned at 700: the MariaDB image chowns its own data
# directory and refuses one somebody claimed first. uploads is the half of this
# install a database dump cannot rebuild. logs and tmp are working space.

sudo install -d -m 750 -o "$run_uid" -g "$run_gid" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/uploads" "$APP_DIR/logs" "$APP_DIR/tmp"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the three secrets, on the server ----------------------------
#
# APP_KEY has to decode to exactly 32 bytes or the container refuses to boot.
# Hex for the two database passwords, because upstream warns that a DB_PASSWORD
# carrying punctuation has to be quoted. Read them back later, if you ever need
# to, with
#   sudo grep DB_PASSWORD /srv/lychee/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		APP_URL=https://${DOMAIN_HOST}
		APP_KEY=base64:$(openssl rand -base64 32)
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	printf 'PUID=%s\nPGID=%s\n' "$run_uid" "$run_gid" >> "$APP_DIR/.env"
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-lychee"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8195 nor 3306 is one of them ------------

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8195 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start runs the database migrations and caches config, routes and
# views, so the wait loop below is generous on purpose.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/up"
code=""
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/up" || echo 000)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "$code" = "200" ] || die "/up answered ${code}. Check: docker compose logs --tail 40 lychee"

curl -sS "https://${DOMAIN_HOST}/up" | grep -q 'Lychee is up' \
	|| die "/up answered 200 without the 'Lychee is up' heading. Check: docker compose logs --tail 40 lychee"

# Before an administrator exists, Lychee redirects every page to the setup form.
root_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || echo 000)"
[ "$root_code" = "307" ] || die "the site root answered ${root_code}, not the 307 an un-claimed Lychee sends. Stop and investigate."

curl -sS "https://${DOMAIN_HOST}/install/admin" | grep -q 'Set up admin account' \
	|| die "the setup form is not being served. Check: docker compose logs --tail 40 lychee"

# --- 7. The first backup, before day one ends --------------------------------
#
# Taken now, with an empty gallery, so the restore path is proved before there
# is anything to lose. The archive carries .env, compose.yml, the uploads tree
# and the live Caddy site block rather than the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/lychee-db-${STAMP}.sql.gz"
sudo tar -czf "$APP_DIR/backups/lychee-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/lychee-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/lychee-files-${STAMP}.tar.gz" ] || die "the file archive is empty"

cat <<-DONE

	Lychee is serving its admin setup form at https://${DOMAIN_HOST}/install/admin

	  1. Open that page NOW and claim the account. The form is unauthenticated,
	     because there is no account yet to authenticate against, and whoever
	     submits it first is the administrator of this gallery. Fill in a
	     username and a password twice and press Create admin account. You
	     should land on "Admin account has been created." That account is this
	     gallery's only credential and no mail is relayed from this install, so
	     there is no password reset: put it in your password manager first.
	  2. Then prove the door is shut. This is the security check the script
	     cannot run for you, because the account does not exist until you make
	     it:
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/install/admin
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/
	     The first must print 403, the guard that throws "Admin User has
	     already been set". The second must print 200, the gallery itself. A
	     307 on the first means no account was created and the form is still
	     open to the internet.
	  3. Self-registration is already off. Lychee ships user_registration_enabled
	     set to 0 and nothing here changes it, so the form above was the only
	     way in.
	  4. Your first upload will look like it has hung. There is no worker in
	     this stack, so the request that carries a photo up also builds every
	     resized variant before it answers. Watch
	       cd $APP_DIR && docker compose logs -f lychee
	     rather than the progress bar.
	  5. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding .env, compose.yml, the uploads tree and the live Caddy
	     site block. Take them again once you have an account, because this
	     pair predates it. They sit on the same disk as the data, which is not
	     a backup. Copy them off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/lychee/

DONE
