This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing Piwigo 16.4.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. `<DOMAIN>` is the address every album link and every photo URL you
hand out will carry. Piwigo does not force you to keep it, but a gallery other people have
bookmarked is expensive to move, so pick the hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `10` G free, `amd64` or `arm64`, and your
server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. The 10 GB is the install
plus room for the first photos and the resized copies Piwigo makes from each one; a real library
needs whatever that library weighs, and a photo gallery is the one app on this site where the
disk line on your invoice is the line that matters.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/piwigo /srv/piwigo/backups /srv/piwigo/gallery
sudo install -d -m 700 /srv/piwigo/mariadb
ls -la /srv/piwigo
```

You should see: `backups` and `gallery` owned by you, and `mariadb` at mode `drwx------` owned by
root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it refuse
to initialise. `gallery` is the whole of Piwigo on disk: the PHP tree the image copies in on first
start, the config the installer writes under `local/config`, and every photo you upload after.

## 3. Secrets

Two secrets, both generated here on the server and both written straight into a file only you can
read: the password for the `piwigo` database user, and the MariaDB root password. Piwigo ships no
account of its own, so the webmaster is the one you create in the browser in step 7.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines separately in different shells. Run `chmod 600 /srv/piwigo/.env` and carry on. If
the file already existed from an earlier attempt, this block has now overwritten both secrets,
which is fine before the database exists and a problem afterwards: MariaDB keeps the password it
was created with, so a changed `DB_PASSWORD` on an existing directory produces an access-denied
error rather than anything that mentions passwords.

Do not paste that file, either secret, or any output containing them into this chat window. You
will read `DB_PASSWORD` once in step 7 to type it into the installer form in your browser, and it
goes from the terminal to the browser and nowhere else.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/piwigo/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/piwigo/compose.yml` and paste again in one go. No database port is published here,
and no credential is written in this file; every value arrives from `.env`.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in the
block with your hostname before you paste. The first line takes a copy, because a syntax error
here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-piwigo /etc/caddy/Caddyfile`, reload, and
paste again. There is no https setting to configure inside Piwigo: it reads `X-Forwarded-Proto`,
which Caddy sets on every proxied request, and that is how the links it prints know they are
https even though the container speaks plain http.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8159` or `3306`.

If you do not: delete anything for `8159` or `3306` with `sudo ufw delete allow 8159`. 80/tcp
redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, and 443/udp is
HTTP/3. Piwigo's own image notes warn that Docker writes its own rules ahead of the firewall's,
which is why the compose file binds 8159 to 127.0.0.1 instead of relying on a rule to keep it
shut, and why 3306 is never published at all. `Status: inactive` is a different problem: Prompt
Zero left this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts
it back before you go any further.

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

You should see, in order: the loop reaching `200`, then `1`, then `302`.

If you do not: the `302` is the one worth understanding. Piwigo sends every page to install.php
until the installer has run, so a redirect at the root is correct rather than broken. If the loop
never reaches `200`, run `docker compose logs --tail 20 db` first, because a database that never
reports healthy is step 2 done wrong, and `docker compose logs --tail 40 piwigo` second. A lasting
`502` is step 5. A container that says `Up` proves nothing on its own.

The first screen at https://<DOMAIN>/install.php shows the heading `Version 16.4.0 - Installation`
above three boxes, `Basic configuration`, `Database configuration` and `Admin configuration`, with
a `Start Install` button underneath.

Now open that page in your browser and fill the form. Use exactly these values in the database
box: Host `db`, User `piwigo`, Database name `piwigo`, and leave Database table prefix on
`piwigo_`. For the Password field in that box, read the value on the server with

```bash
sudo grep DB_PASSWORD /srv/piwigo/.env
```

and copy it straight into the browser. Do not paste it back here. In the admin box, choose your
own username, password and email address: that account is this gallery's only credential and
there is no password-reset mail, so put it in your password manager before you press the button.
Untick `Send my connection settings by email`, because nothing in this install relays mail to the
outside world and that message is not a copy of anything. Then press `Start Install`.

You should see: a page saying the installation is completed, with a link into the gallery.

If you do not: `Connection to server succeeded, but it was impossible to connect to database` is
the database name or user typed wrong, and a failure on the host line means you typed something
other than `db`. Both are safe to correct and submit again.

Once the installer has finished, close the door it leaves open and prove it is shut:

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

You should see, in order: exactly `Piwigo is already installed`, then `403`, then
`{"stat":"ok","result":"16.4.0"}`, then `200`.

If you do not: the `403` is the one that matters. Piwigo ships with user registration switched on,
so until that UPDATE runs, anyone who finds https://<DOMAIN>/register.php can make themselves an
account on your gallery. A `200` there means the setting did not change: check that the UPDATE
printed no error, and run the four commands again. `Piwigo is already installed` is Piwigo's own
words, printed by install.php once the config file exists, so seeing it means nobody who finds
that URL gets a second setup form. The API line is PHP talking to MariaDB and back; the last
`200` is the gallery itself, now that the redirect to the installer is gone.

## 8. First backup and restore

Two artifacts. The dump holds the albums, tags, users, permissions and every photo's metadata. The
file archive holds the photos and the config that rebuilds the service around them.

```bash
cd /srv/piwigo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/piwigo/backups/piwigo-db-$(date +%F).sql.gz
sudo tar --exclude='gallery/_data' -czf /srv/piwigo/backups/piwigo-files-$(date +%F).tar.gz -C /srv/piwigo compose.yml .env gallery -C /etc/caddy Caddyfile
ls -lh /srv/piwigo/backups/
```

You should see: two files, the dump a few tens of kilobytes and the archive a few tens of
megabytes on a fresh install, because the archive carries Piwigo's own PHP tree along with your
photos. Nothing goes offline: `--single-transaction` snapshots a running InnoDB database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed
and the shell created the file anyway. Run the dump line without `| gzip` to read the error.
`gallery/_data` is excluded on purpose: it holds the resized copies Piwigo rebuilds on demand from
your originals, and on a real library it is the largest thing in the tree and the only disposable
one.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/piwigo
scp vps:/srv/piwigo/backups/* ~/backups/piwigo/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/piwigo/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty gallery:

```bash
cd /srv/piwigo
docker compose down
sudo rm -rf /srv/piwigo/mariadb /srv/piwigo/gallery
sudo install -d -m 700 /srv/piwigo/mariadb
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/piwigo/gallery
sudo tar -xzf /srv/piwigo/backups/piwigo-files-$(date +%F).tar.gz -C /srv/piwigo
docker compose up -d db
sleep 30
gunzip -c /srv/piwigo/backups/piwigo-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 20
curl -sS 'https://<DOMAIN>/ws.php?format=json&method=pwg.getVersion'
```

You should see: no output from the restore itself, then `{"stat":"ok","result":"16.4.0"}` from the
last line, which means the gallery came back from a database and a directory that were both
deleted.

If you do not: `Access denied for user 'piwigo'` means the archive did not restore `.env` before
MariaDB initialised its empty directory, so it invented a different password. Repeat the block and
check that the tar step runs before `docker compose up -d db`. That ordering is the whole lesson:
`.env` carries the database password and `gallery/local/config/database.inc.php` is what tells
Piwigo it has already been installed, so a restore missing either one lands you back on the
installer with a gallery full of orphaned files.

## 9. Updating later

Versions are listed at https://github.com/Piwigo/Piwigo/releases and the image tags carrying them
at https://hub.docker.com/r/piwigo/piwigo/tags. Take both backup artifacts first, then edit the
piwigo `image:` line in /srv/piwigo/compose.yml to the new tag and its digest.

```bash
cd /srv/piwigo
docker compose pull
docker compose up -d
docker compose logs --tail 40 piwigo
```

You should see: `Updating to piwigo version` followed by the new number, then nginx and php-fpm
starting, and no repeating restart.

If you do not: `Current piwigo version` and the old number means the pull did not take, so check
the digest you pasted. Put the old tag and digest back if anything looks wrong, run the same three
commands, and re-run step 7's `pwg.getVersion` check before you call the update done. Piwigo asks
for its own database upgrade the first time an administrator signs in after a version bump; say
yes to it in the browser.

## 10. What will probably go wrong

The gallery is public the moment the installer finishes, and that surprised me. Piwigo ships with
guest browsing on, which is the right default for the thing Flickr sold and the wrong one if you
assumed a private server meant a private gallery. Nothing in this install changes it, because the
fix is editorial rather than operational: in Administration an album is set private and access
granted to named users or groups, one album at a time. Decide that before your first upload, not
after, because a photo that was public for an afternoon was public.

## 11. Out of scope

- Do not configure SMTP or a mail relay. The gallery works without mail; what mail buys is
  password reset and comment notification, and that is a second install to do properly.
- Do not turn user registration back on to let friends comment. Step 7 closed it deliberately;
  Piwigo creates accounts for named people in Administration instead.
- Do not install plugins or themes from the Piwigo extension gallery yet. Each writes into the
  directory the image overwrites on upgrade, and this install has one backup.
- Do not mount a scripts directory or set up an FTP synchronise path. Both add a way in that this
  install neither backs up nor checks.
