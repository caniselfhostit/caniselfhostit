This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing PhotoPrism 260728-ce on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box.

Read this before step 1, because it decides whether you want the install at all. PhotoPrism
organises, searches and shows photographs. It does not develop them: there is no exposure
slider, no masking, no presets and no history stack. It replaces the catalogue half of
Lightroom, and the other half stays where it is.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
free -m | awk '/^Swap:/ {print $2 " MB swap"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `3072` MB available, a swap figure that is not `0`, at least `10` G
free, `amd64` or `arm64`, and your server's IP on the last line. Upstream asks for 2 cores,
3 GB of physical memory and 4 GB of swap. A box sold as 3 GB shows less than 3072 MB
available, so plan on 4 GB.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a name
nobody resolves and failed attempts count against a rate limit you cannot see. `0 MB swap` is
worth fixing before you index anything: the indexer spikes on large files and a box with no
swap restarts in the middle instead of finishing. And if total memory is under 1 GB,
PhotoPrism switches TensorFlow and RAW indexing off by itself, which looks like a working
install with the search quietly missing.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/photoprism /srv/photoprism/backups /srv/photoprism/originals /srv/photoprism/storage
sudo install -d -m 700 /srv/photoprism/mariadb
ls -la /srv/photoprism
```

You should see: `backups`, `originals` and `storage` owned by you, and `mariadb` at mode
`drwx------` owned by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `originals` is the library, the only directory that will hold
photographs; `storage` is cache, sidecar YAML and the nightly database dump PhotoPrism writes
for itself.

## 3. Secrets

Three secrets, all generated here on the server, all straight into a file only you can read:
the initial admin password, the `photoprism` database user's password, and the MariaDB root
password.

```bash
umask 077
cat > /srv/photoprism/.env <<EOF
PHOTOPRISM_SITE_URL=https://<DOMAIN>/
PHOTOPRISM_ADMIN_PASSWORD=$(openssl rand -hex 24)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
printf 'PHOTOPRISM_UID=%s\nPHOTOPRISM_GID=%s\n' "$(id -u)" "$(id -g)" >> /srv/photoprism/.env
chmod 600 /srv/photoprism/.env
umask 022
ls -l /srv/photoprism/.env
id -u
```

You should see: mode `-rw-------`, your own username twice, and `id -u` printing a number
inside the ranges upstream supports for the id the container drops to after start-up, which
are 0, 33, 50-99, 500-600, 900-1250 and 2000-2100. A first user on a fresh VPS is 1000.
Replace `<DOMAIN>` on the first line with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/photoprism/.env` and
carry on. If `id -u` printed something outside those ranges, stop and ask before editing the
file, because the container uses that number with `setpriv`. If the file already existed from
an earlier attempt, this block has now overwritten all three secrets, which is fine before the
database exists and a problem afterwards: MariaDB keeps the password it was created with, so a
changed `DB_PASSWORD` on an existing directory produces an authentication failure in the
PhotoPrism log rather than anything about passwords.

Do not paste that file, any of the three secrets, or any command output containing them into
this chat window. The agent path never sees those values; this one will hand them to a third
party unless you keep them out.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/photoprism/compose.yml <<'EOF'
# PhotoPrism · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose .. https://docs.photoprism.app/getting-started/docker-compose/
#   config options .. https://docs.photoprism.app/getting-started/config-options/
#   behind a proxy .. https://docs.photoprism.app/getting-started/proxies/traefik/
#   open source faq . https://www.photoprism.app/oss/faq
#
# Two services: PhotoPrism and the MariaDB holding the index. The image is the
# "ce" build, which upstream describes as the Community Edition distributed
# under the AGPL; the unsuffixed Docker Hub tags carry their Plus License.
# MariaDB 11.8 is the current long-term release, above the 10.5.12 floor
# upstream states. PHOTOPRISM_INIT is empty and DEFAULT_TLS false, so the
# container installs nothing and generates no certificate at start-up. Every
# ${...} comes from /srv/photoprism/.env, mode 600, which Compose reads and
# never mounts. Digests read 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mariadb:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: photoprism-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    environment:
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DATABASE: photoprism
      MARIADB_USER: photoprism
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
    volumes:
      - /srv/photoprism/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  photoprism:
    image: photoprism/photoprism:260728-ce@sha256:15deeb6cc6c31f043625579a29a0e26f5f7b328441fc3945a7a0b7e4b54c0a18
    container_name: photoprism
    restart: unless-stopped
    # Relaxed as upstream's example does, for the tools the indexer runs.
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    working_dir: /photoprism
    environment:
      PHOTOPRISM_ADMIN_USER: "admin"
      PHOTOPRISM_ADMIN_PASSWORD: "${PHOTOPRISM_ADMIN_PASSWORD}"
      PHOTOPRISM_AUTH_MODE: "password"
      # Caddy reaches this over the Docker bridge, inside the proxy range
      # PhotoPrism trusts by default.
      PHOTOPRISM_SITE_URL: "${PHOTOPRISM_SITE_URL}"
      PHOTOPRISM_SITE_CAPTION: ""
      PHOTOPRISM_DISABLE_TLS: "true"
      PHOTOPRISM_DEFAULT_TLS: "false"
      # Nothing is installed on first start: the container downloads nothing.
      PHOTOPRISM_INIT: ""
      PHOTOPRISM_DISABLE_MCP: "true"
      PHOTOPRISM_BACKUP_DATABASE: "true"
      PHOTOPRISM_DATABASE_DRIVER: "mysql"
      PHOTOPRISM_DATABASE_SERVER: "mariadb:3306"
      PHOTOPRISM_DATABASE_NAME: "photoprism"
      PHOTOPRISM_DATABASE_USER: "photoprism"
      PHOTOPRISM_DATABASE_PASSWORD: "${DB_PASSWORD}"
      # Drops to the login user after start-up, so the photographs belong
      # to a person rather than to root.
      PHOTOPRISM_UID: "${PHOTOPRISM_UID}"
      PHOTOPRISM_GID: "${PHOTOPRISM_GID}"
    volumes:
      # The library: everything indexed lives here.
      - /srv/photoprism/originals:/photoprism/originals
      # Cache, sidecar YAML and the nightly dump.
      - /srv/photoprism/storage:/photoprism/storage
    ports:
      # Loopback only: the host's Caddy alone reaches 8164.
      - "127.0.0.1:8164:2342"
    depends_on:
      mariadb:
        condition: service_healthy
EOF
cd /srv/photoprism && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/photoprism/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your
terminal: run `rm /srv/photoprism/compose.yml` and paste again in one go. The image is the
`-ce` build on purpose. Upstream describes that tag as the Community Edition distributed under
the AGPL, and says the unsuffixed tags on Docker Hub carry their own Plus License instead;
this catalogue records PhotoPrism as AGPL-3.0, so the pin has to be the build that claim is
true of.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-photoprism
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# PhotoPrism · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.photoprism.app/getting-started/proxies/traefik/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed, with
# <DOMAIN> replaced by the hostname pointed at this box. That hostname is also
# PHOTOPRISM_SITE_URL in .env, and the two have to say the same thing.

<DOMAIN> {
	# No `encode`: PhotoPrism compresses its own API responses, and JPEG,
	# HEIC and video do not compress twice.

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8164 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8164
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-photoprism /etc/caddy/Caddyfile`,
reload, and paste again. Caddy terminates TLS and speaks plain http to the container, which is
why `PHOTOPRISM_DISABLE_TLS` is `true` in the compose file: without it PhotoPrism would try to
serve its own certificate on a port only Caddy ever connects to.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8164` or `3306`.

If you do not: delete anything for `8164` or `3306` with `sudo ufw delete allow 8164`. 8164 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp answers the ACME challenge and redirects
to HTTPS, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by default.
`Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

The first start creates the database schema and the superadmin account. The image is about a
gigabyte, so the pull is the slow part.

```bash
cd /srv/photoprism
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/api/v1/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/api/v1/status
curl -sS -o /dev/null -w '%{http_code}\n' 'https://<DOMAIN>/api/v1/photos?count=1'
curl -sS https://<DOMAIN>/ | grep -c '<title>PhotoPrism</title>'
```

You should see, in order: the loop reaching `200`, then exactly
`{"status":"operational"}`, then `401`, then `1`.

If you do not: the `401` is the one worth understanding. It means the API is up and refusing a
call with no session, which is what `PHOTOPRISM_AUTH_MODE=password` buys you. A `200` in its
place would mean the library is set to public and every photograph is visible to anyone who
finds the address, and you should stop and fix that before uploading anything. A `404` instead
means Caddy is not reaching the container: check `docker compose ps`. If the loop never
reaches `200`, run `docker compose logs --tail 20 mariadb` first, because a database that
never reports healthy is step 2 done wrong, and `docker compose logs --tail 40 photoprism`
second.

The first screen at https://<DOMAIN> is a sign-in card with a `Name` field, a `Password` field
and a `Sign in` button. Sign in as `admin`, with the password you read once with
`sudo grep PHOTOPRISM_ADMIN_PASSWORD /srv/photoprism/.env`, and put it in your password
manager. Then change it inside PhotoPrism, in Settings, then Account. Editing that .env line
afterwards does nothing at all: the variable is read only when the account is created, which
already happened.

## 8. First backup and restore

Two artifacts, and they are not interchangeable. The dump is the index: albums, labels, faces,
places and where every file is. The archive is the configuration and the sidecar YAML. Neither
one contains a photograph, and the photographs are the third thing.

```bash
cd /srv/photoprism
docker compose exec -T mariadb sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/photoprism/backups/photoprism-db-$(date +%F).sql.gz
sudo tar --exclude='storage/cache' -czf /srv/photoprism/backups/photoprism-config-$(date +%F).tar.gz -C /srv/photoprism compose.yml .env storage -C /etc/caddy Caddyfile
ls -lh /srv/photoprism/backups/
```

You should see: two files, both a few kilobytes to a few megabytes on a fresh install. Nothing
goes offline: `--single-transaction` snapshots a running InnoDB database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read the
error.

A backup on the same disk as the data is not a backup, and neither of those files holds a
single photograph. Run all of these on your own machine, not the server:

```bash
mkdir -p ~/backups/photoprism
scp vps:/srv/photoprism/backups/* ~/backups/photoprism/
rsync -a vps:/srv/photoprism/originals/ ~/backups/photoprism/originals/
```

You should see: two files copied, and the rsync finishing without error. On a fresh install
the originals directory is empty and the rsync takes a second; once you have a library it is
the long one, and it is the only copy of the pictures.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty library:

```bash
cd /srv/photoprism
docker compose down
sudo rm -rf /srv/photoprism/mariadb
sudo install -d -m 700 /srv/photoprism/mariadb
docker compose up -d mariadb
sleep 30
gunzip -c /srv/photoprism/backups/photoprism-db-$(date +%F).sql.gz | docker compose exec -T mariadb sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 20
curl -sS https://<DOMAIN>/api/v1/status
```

You should see: no output from the restore itself, then `{"status":"operational"}` from the
last command, which means the schema survived a database directory that was deleted and
rebuilt.

If you do not: `Access denied for user 'photoprism'` means .env was not in place when MariaDB
initialised the empty directory, so it created the account with a blank password. Untar the
config archive into /srv/photoprism and start again from `docker compose down`. Understand the
stakes before you skip this: the dump knows where every photograph is, the originals directory
is every photograph, and either one alone rebuilds nothing.

## 9. Updating later

Releases are datestamped and listed at https://github.com/photoprism/photoprism/releases, and
the AGPL image for each carries the `-ce` suffix on Docker Hub. Take both backup artifacts
first, then edit the photoprism `image:` line in /srv/photoprism/compose.yml to the new tag and
its digest.

```bash
cd /srv/photoprism
docker compose pull
docker compose up -d
docker compose logs --tail 40 photoprism
```

You should see: migration lines, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
step 7's status check before you call the update done. Upstream does not backport fixes to
older datestamps, so an instance left alone for a year updates in one jump rather than a
staircase, and that jump is the one to take a backup before.

## 10. What will probably go wrong

You will copy a folder of photographs into /srv/photoprism/originals, reload the browser, and
see an empty library. I did, and spent ten minutes checking the mount, which was fine.
PhotoPrism does not watch that directory: the automatic index fires only for files arriving
over WebDAV, and anything put there another way sits unseen until somebody runs
`docker compose exec -T photoprism photoprism index`, which takes a while on a large folder.

## 11. Out of scope

- Do not add the ollama or open-webui services from upstream's example compose file. They are
  two more containers and a multi-gigabyte model download.
- Do not set `PHOTOPRISM_AUTH_MODE` to `public`. It removes the sign-in screen from a service
  the whole internet can reach, and step 7 asserts against that.
- Do not switch to the unsuffixed image tag for membership features. That build ships under
  PhotoPrism's Plus License rather than the AGPL, and the licence is your decision to make
  deliberately.
- Do not configure hardware video transcoding or mount /dev/dri. It needs devices this install
  never checked for.
