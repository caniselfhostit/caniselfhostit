#!/usr/bin/env bash
# Piwigo · the agent-free install.
#
# Everything prompt.md tells an agent to do, as a script you can read first.
# Run it on the VPS, as a non-root user who is in the docker group:
#
#   DOMAIN_HOST=photos.example.com ./install.sh
#
# Authored by caniselfhostit from the upstream documentation:
#   https://piwigo.org/guides/install/docker
#   https://piwigo.org/guides/install/requirements
#   https://github.com/Piwigo/piwigo-docker/blob/v16.4a/README.md
#   https://github.com/Piwigo/piwigo-docker/blob/v16.4a/config/init-script.sh
#
# The image is the Piwigo project's own, pinned by tag and digest.
#
# Two secrets are generated here, on this machine: the piwigo database user's
# password and the MariaDB root password. Both go into /srv/piwigo/.env with
# mode 600 and neither is ever printed. Piwigo ships no account of its own, so
# the webmaster is created by you in the browser installer this script leaves
# waiting, and the closing notes list the checks to run once you have.
#
# DOMAIN_HOST is the address every album link and photo URL will carry.
#
# NOT YET VERIFIED: no harness run has been recorded against this script.
set -euo pipefail

APP_DIR="${APP_DIR:-/srv/piwigo}"
DOMAIN_HOST="${DOMAIN_HOST:-}"

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }

# --- 1. Refuse to start on a machine that is not ready -----------------------

[ -n "$DOMAIN_HOST" ] || die "set DOMAIN_HOST to the hostname you pointed at this server, e.g. photos.example.com"
command -v docker >/dev/null 2>&1 || die "docker is not installed. Run Prompt Zero first."
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing"
command -v caddy >/dev/null 2>&1 || die "caddy is not installed on the host. Run Prompt Zero first."
command -v openssl >/dev/null 2>&1 || die "openssl is not installed"

avail_mb="$(free -m | awk '/^Mem:/ {print $7}')"
[ "$avail_mb" -ge 1024 ] || die "only ${avail_mb} MB of RAM available; PHP plus MariaDB wants 1024 MB"
avail_gb="$(df -BG --output=avail /srv | tail -1 | tr -dc '0-9')"
[ "$avail_gb" -ge 10 ] || die "only ${avail_gb} GB free on /srv; this install wants 10 GB, and a photo library wants more"

resolved="$(getent hosts "$DOMAIN_HOST" | awk '{print $1; exit}' || true)"
[ -n "$resolved" ] || die "$DOMAIN_HOST does not resolve yet. Add the A record, wait a minute, run this again."

# --- 2. Lay the files out ----------------------------------------------------
#
# mariadb stays root-owned at 700: the MariaDB image chowns its own data
# directory and refuses one somebody claimed first. gallery is the whole of
# Piwigo on disk, application tree and photos together.

sudo install -d -m 750 -o "$(id -u)" -g "$(id -g)" "$APP_DIR" "$APP_DIR/backups" "$APP_DIR/gallery"
sudo install -d -m 700 "$APP_DIR/mariadb"
install -m 0644 "$(dirname "$0")/compose.yml" "$APP_DIR/compose.yml"
install -m 0644 "$(dirname "$0")/Caddyfile" "$APP_DIR/Caddyfile"

# --- 3. Generate the two secrets, on the server ------------------------------
#
# Hex rather than base64 for both: one is typed into a browser form and the
# other travels in a connection string, and neither wants escaping. Read the
# database password later with
#   sudo grep DB_PASSWORD /srv/piwigo/.env

if [ ! -f "$APP_DIR/.env" ]; then
	umask 077
	cat > "$APP_DIR/.env" <<-ENVFILE
		DB_PASSWORD=$(openssl rand -hex 32)
		MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
	ENVFILE
	printf 'PIWIGO_UID=%s\nPIWIGO_GID=%s\n' "$(id -u)" "$(id -g)" >> "$APP_DIR/.env"
	chmod 600 "$APP_DIR/.env"
	umask 022
fi

cd "$APP_DIR"
docker compose config >/dev/null

# --- 4. Caddy site block, on the host ----------------------------------------

if ! sudo grep -qF "$DOMAIN_HOST {" /etc/caddy/Caddyfile; then
	sudo cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.before-piwigo"
	printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
	sed "s|<DOMAIN>|${DOMAIN_HOST}|g" "$APP_DIR/Caddyfile" | sudo tee -a /etc/caddy/Caddyfile >/dev/null
fi
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy

# --- 5. Ports: two open, and neither 8159 nor 3306 is one of them ------------
#
# Upstream's image notes warn that Docker writes its own rules ahead of the
# firewall's, which is why 8159 is bound to 127.0.0.1 in compose.yml rather
# than left open and filtered here.

if command -v ufw >/dev/null 2>&1; then
	echo "==> 80/tcp and 443/tcp for Caddy, 443/udp for HTTP/3; 8159 and 3306 stay closed"
	sudo ufw allow 80/tcp
	sudo ufw allow 443/tcp
	sudo ufw allow 443/udp
	sudo ufw status verbose
fi

# --- 6. Start it -------------------------------------------------------------
#
# The first start copies about 60 MB of PHP into $APP_DIR/gallery and chowns
# every file in it, so the wait loop below is generous on purpose.

docker compose pull
docker compose up -d

echo "==> waiting for https://${DOMAIN_HOST}/install.php"
for _ in $(seq 1 40); do
	code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/install.php" || true)"
	[ "$code" = "200" ] && break
	sleep 10
done
[ "${code:-}" = "200" ] || die "/install.php answered ${code:-nothing}. Check: docker compose logs --tail 40 piwigo"

curl -sS "https://${DOMAIN_HOST}/install.php" | grep -q 'Start Install' \
	|| die "install.php answered 200 without the Start Install button. Check: docker compose logs --tail 40 piwigo"

# Before the installer runs, Piwigo sends every other page to install.php.
root_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${DOMAIN_HOST}/" || true)"
[ "$root_code" = "302" ] || die "the site root answered ${root_code}, not the 302 an uninstalled Piwigo sends. Stop and investigate."

# --- 7. The first backup, before day one ends --------------------------------
#
# Taken now, with an empty gallery, so the restore path is proved before there
# is anything to lose. The dump is a schemaless MariaDB at this point; the
# archive already carries .env, the Piwigo tree and the live Caddy site block
# rather than the <DOMAIN> template.

STAMP="$(date +%Y%m%d-%H%M%S)"
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > "$APP_DIR/backups/piwigo-db-${STAMP}.sql.gz"
sudo tar --exclude='gallery/_data' -czf "$APP_DIR/backups/piwigo-files-${STAMP}.tar.gz" -C "$APP_DIR" compose.yml .env gallery -C /etc/caddy Caddyfile
ls -lh "$APP_DIR/backups/"
[ -s "$APP_DIR/backups/piwigo-db-${STAMP}.sql.gz" ] || die "the database dump is empty"
[ -s "$APP_DIR/backups/piwigo-files-${STAMP}.tar.gz" ] || die "the file archive is empty"

cat <<-DONE

	Piwigo is serving its installer at https://${DOMAIN_HOST}/install.php

	  1. Open that page now and fill the form. In the database box use Host db,
	     User piwigo, Database name piwigo, and leave the table prefix on piwigo_.
	     Read the password with
	       sudo grep DB_PASSWORD $APP_DIR/.env
	     and copy it into that box. It was not printed here. In the admin box
	     choose your own username, password and email: that account is this
	     gallery's only credential and no mail is relayed from this install, so
	     put it in your password manager before you press Start Install. Untick
	     "Send my connection settings by email" for the same reason.
	  2. Then close the door the installer leaves open. Piwigo ships with user
	     registration switched on, so until you run this anyone who finds
	     https://${DOMAIN_HOST}/register.php can create an account on your gallery:
	       cd $APP_DIR && docker compose exec -T db sh -c 'exec mariadb -u"\$MARIADB_USER" -p"\$MARIADB_PASSWORD" -e "UPDATE piwigo_config SET value = '"'"'false'"'"' WHERE param = '"'"'allow_user_registration'"'"'" "\$MARIADB_DATABASE"'
	       curl -sS -o /dev/null -w '%{http_code}\n' https://${DOMAIN_HOST}/register.php
	     That must print 403. This is the security check the script cannot run
	     for you, because the table does not exist until the installer has run.
	  3. Prove the install is real and the setup form is gone:
	       curl -sS https://${DOMAIN_HOST}/install.php
	       curl -sS 'https://${DOMAIN_HOST}/ws.php?format=json&method=pwg.getVersion'
	     The first must print exactly "Piwigo is already installed", the second
	     {"stat":"ok","result":"16.4.0"}.
	  4. Your gallery is public. Piwigo ships with guest browsing on, so anyone
	     with the address can see every album you have not made private. Set
	     album permissions in Administration before your first upload.
	  5. First backup written to $APP_DIR/backups: a database dump and a file
	     archive holding .env, the whole gallery tree and the live Caddy site
	     block. Take them again after the installer has run, because this pair
	     predates your account. They are on the same disk as the data, which is
	     not a backup. Copy them off the box tonight:
	       scp vps:$APP_DIR/backups/* ~/backups/piwigo/

DONE
