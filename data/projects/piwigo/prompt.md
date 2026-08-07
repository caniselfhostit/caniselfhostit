You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Piwigo 16.4.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here, and it is the address every album link and every photo URL
they hand out will carry, so a gallery people have bookmarked is expensive to move.

Piwigo and its database need 1024 MB of RAM available and 10 GB free on /srv: the install plus
room for the first photos and the resized copies Piwigo makes from each one, not a library. Both
images publish amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name nobody resolves.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/piwigo /srv/piwigo/backups /srv/piwigo/gallery
sudo install -d -m 700 /srv/piwigo/mariadb
ls -la /srv/piwigo
```

Assert: `backups` and `gallery` owned by the login user, `mariadb` at mode `700` owned by root.
Leave that one alone; the MariaDB image chowns its own data directory and refuses one somebody
claimed first. `gallery` is the whole of Piwigo on disk: the PHP tree the image copies in, the
config the installer writes under `local/config`, and every photo uploaded after.

## 3. Secrets

Two secrets: the `piwigo` database user's password and the MariaDB root password. Piwigo ships no
account and no admin token, so the webmaster is created by the user in the browser in step 7.
Print neither value, and keep both out of your summary and every log line.

```bash
umask 077
cat > /srv/piwigo/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
printf 'PIWIGO_UID=%s\nPIWIGO_GID=%s\n' "$(id -u)" "$(id -g)" >> /srv/piwigo/.env
chmod 600 /srv/piwigo/.env
umask 022
ls -l /srv/piwigo/.env
```

Assert: mode `-rw-------` and the login user's name twice. Compose reads this file for the
`${...}` substitutions in compose.yml and never mounts it into a container. `DB_PASSWORD` is read
back once, in step 7, and nothing else ever needs it.

## 4. compose.yml

```bash
cat > /srv/piwigo/compose.yml <<'EOF'
# Piwigo · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ... https://piwigo.org/guides/install/docker
#   requirements ..... https://piwigo.org/guides/install/requirements
#   image README ..... https://github.com/Piwigo/piwigo-docker/blob/v16.4a/README.md
#   image init ....... https://github.com/Piwigo/piwigo-docker/blob/v16.4a/config/init-script.sh
#
# The image is the Piwigo project's own, built from github.com/Piwigo/piwigo-docker:
# Alpine with nginx and php-fpm, tagged 16.4.0a for Piwigo 16.4.0. Two services:
# Piwigo, and the MariaDB holding albums, tags, permissions and every photo's
# metadata. The PHP tree and the photo files share /srv/piwigo/gallery, which the
# image populates on first start. Upstream also mounts a scripts directory that
# runs shell code as root inside the container; this file leaves it out. Every
# ${...} comes from /srv/piwigo/.env, mode 600, which Compose reads and never
# mounts. Digests read 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: piwigo-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: piwigo
      MARIADB_USER: piwigo
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/piwigo/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  piwigo:
    image: piwigo/piwigo:16.4.0a@sha256:0ec6f159a3f972338b64e299d56ac37c442dd26cbeec39320d76ea826b5e0b84
    container_name: piwigo
    restart: unless-stopped
    environment:
      # The image's init reads TZ with `set -u`, so it is never left unset.
      TZ: Etc/UTC
      # The gallery tree is chowned to these on every start, so the login
      # user can read the photos without sudo.
      PIWIGO_UID: "${PIWIGO_UID}"
      PIWIGO_GID: "${PIWIGO_GID}"
    volumes:
      # One directory: the release the image ships, the config the installer
      # writes to local/config, and every photo uploaded afterwards.
      - /srv/piwigo/gallery:/var/www/html/piwigo
    healthcheck:
      # / answers 302 to install.php before the installer runs and 200 after.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/ || exit 1"]
      start_period: 60s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: the host's Caddy alone reaches 8159, and the container
      # listens on 80 with nginx running as its own unprivileged user.
      - "127.0.0.1:8159:80"
    depends_on:
      db:
        condition: service_healthy
EOF
cd /srv/piwigo && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No database port is published and no credential is written
here; every value arrives from .env.

## 5. Caddy and TLS

Append the block below, with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-piwigo
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Piwigo · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://piwigo.org/guides/install/docker and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. Piwigo decides
# whether the absolute links it prints say https by reading X-Forwarded-Proto,
# and reverse_proxy sets that header on every request without being asked.

<DOMAIN> {
	encode zstd gzip

	# Piwigo serves its own pages and the photo files. These four are the
	# headers a reverse proxy is the right place for.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8159 is the loopback port compose publishes here, not a container port
	# and not open in the firewall.
	reverse_proxy 127.0.0.1:8159
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-piwigo, reload, and
report the objection. Caddy gets the certificate on first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8159 is bound to 127.0.0.1 and 3306 is never published, so neither has a host port a rule
could apply to. Upstream warns Docker writes its own rules ahead of the firewall's, which is why
8159 is on loopback rather than open and filtered. Assert: `Status: active`, rules for 80,
443/tcp and 443/udp, nothing else.

## 7. Start and verify

The first start copies about 60 MB of PHP into /srv/piwigo/gallery and chowns every file in it.
Give it a minute before concluding anything.

```bash
cd /srv/piwigo
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/install.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/install.php | grep -c 'Start Install'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert all three, printing what you received. The loop ends on `200`, the grep prints `1`, and
the last prints `302`, because Piwigo sends every page to install.php until the installer has run.
If any misses, stop, run `docker compose logs --tail 40 piwigo` and
`docker compose logs --tail 20 db`, and name the likely step: a database that never reports
healthy is step 2, a lasting `502` is step 5. A running container is not success.

The first screen at https://<DOMAIN>/install.php shows the heading
`Version 16.4.0 - Installation` above three boxes, `Basic configuration`, `Database configuration`
and `Admin configuration`, with a `Start Install` button underneath.

STOP: tell the user to open https://<DOMAIN>/install.php, fill the form and press Start Install,
and wait. Do not continue until they confirm. Give them these values and nothing else. Host `db`,
User `piwigo`, Database name `piwigo`, Database table prefix `piwigo_` left alone. The password
they fetch themselves with `sudo grep DB_PASSWORD /srv/piwigo/.env`, and it goes in the database
box, not the admin box. In the admin box they choose their own username, password and email; that
account is this gallery's only credential, so it goes in their password manager before they press
the button. Tell them to untick `Send my connection settings by email`: nothing here relays mail,
so that message is not a copy of anything.

Once they confirm, close the door the installer leaves open and prove it is shut:

```bash
cd /srv/piwigo
docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' <<'EOF'
UPDATE piwigo_config SET value = 'false' WHERE param = 'allow_user_registration';
EOF
curl -sS https://<DOMAIN>/install.php
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/register.php
curl -sS 'https://<DOMAIN>/ws.php?format=json&method=pwg.getVersion'
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert all four, printing what you received for each. install.php now answers exactly
`Piwigo is already installed`, so nobody who finds that URL gets a second setup form.
register.php answers `403`, the security assert here: Piwigo ships with open sign-up on, and a
public gallery that lets strangers create accounts is not what the user asked for. The web API
returns `{"stat":"ok","result":"16.4.0"}`, PHP talking to MariaDB and back. The last prints `200`,
the gallery itself. If the register check prints anything but `403`, stop and say so rather than
reporting success.

## 8. First backup and restore

Two artifacts. The dump holds the albums, tags, users, permissions and every photo's metadata.
The file archive holds the photos and the config that rebuilds the service around them.

```bash
cd /srv/piwigo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/piwigo/backups/piwigo-db-$(date +%F).sql.gz
sudo tar --exclude='gallery/_data' -czf /srv/piwigo/backups/piwigo-files-$(date +%F).tar.gz -C /srv/piwigo compose.yml .env gallery -C /etc/caddy Caddyfile
ls -lh /srv/piwigo/backups/
```

Assert: both exist, both are non-empty, both sizes printed. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database. `gallery/_data` is left out on purpose:
it holds the resized copies Piwigo rebuilds on demand from the originals, and on a real library it
is the largest thing in the tree and the only disposable one.

A backup on the same disk is not a backup. Run this one from the user's machine, not the server:

```bash
mkdir -p ~/backups/piwigo
scp vps:/srv/piwigo/backups/* ~/backups/piwigo/
```

To restore: `docker compose down`, `sudo rm -rf /srv/piwigo/mariadb /srv/piwigo/gallery`, recreate
both as step 2 does, untar the file archive into /srv/piwigo so `.env` and the gallery are back
before anything starts, `docker compose up -d db`, wait 30 seconds for healthy, pipe `gunzip -c`
on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`. Tell the user why that order matters: MariaDB reads its password from
`.env` when it initialises an empty directory, and `gallery/local/config/database.inc.php` is what
tells Piwigo it has already been installed. Restore one without the other and they land back on
the installer.

## 9. Updating later

Versions are listed at https://github.com/Piwigo/Piwigo/releases and the image tags carrying them
at https://hub.docker.com/r/piwigo/piwigo/tags. Take both backups first, then edit the piwigo
image line in /srv/piwigo/compose.yml to the new tag and digest:

```bash
cd /srv/piwigo
docker compose pull
docker compose up -d
docker compose logs --tail 40 piwigo
```

The image compares the version it ships against the one in the gallery directory and copies the
newer files over, so the log prints `Updating to piwigo version` and the number. Piwigo then asks
for its database upgrade at the next administrator sign-in. Re-run step 7's `pwg.getVersion`
check afterwards and confirm the number moved.

## 10. What will probably go wrong

The gallery is public the moment the installer finishes, and that surprised me. Piwigo ships with
guest browsing on, the right default for the thing Flickr sold and the wrong one if you assumed a
private server meant a private gallery. Nothing here changes it, because the fix is editorial: in
Administration an album is set private and access granted to named users or groups, one album at a
time. Decide before the first upload, because a photo that was public for an afternoon was
public.

## 11. Out of scope

- Do not configure SMTP or a mail relay. The gallery works without mail; what mail buys is
  password reset and comment notification, and that is a second install to do properly.
- Do not turn user registration back on to let friends comment. Step 7 closed it deliberately;
  Piwigo creates accounts for named people in Administration instead.
- Do not install plugins or themes from the Piwigo extension gallery yet. Each writes into the
  directory the image overwrites on upgrade, and this install has one backup.
- Do not mount a scripts directory or set up an FTP synchronise path. Both add a way in that this
  prompt neither backs up nor checks.
