You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Lychee 7.7.2 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here. Say why when you ask: the hostname becomes `APP_URL`, and
Lychee builds every album link and image URL from it, so moving later breaks links already out.

Lychee and its database need 2048 MB of RAM available and 10 GB free on /srv: the app image is
PHP 8.5 under FrankenPHP with ImageMagick and ffmpeg in it, upstream caps that at 2 GB, and
MariaDB wants its own. Both images publish amd64 and arm64. Measure all five:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
id -u
dig +short <DOMAIN>
```

Under either floor, print both numbers and stop. Do not install and hope. If `dig +short` prints
nothing, print that and stop: Caddy cannot certify a name nobody resolves. If `id -u` prints
under 33, stop: the container's start-up script rejects a `PUID` outside 33 to 65534.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/lychee /srv/lychee/backups /srv/lychee/uploads /srv/lychee/logs /srv/lychee/tmp
sudo install -d -m 700 /srv/lychee/mariadb
ls -la /srv/lychee
```

Assert: `backups`, `uploads`, `logs` and `tmp` owned by the login user, `mariadb` at mode `700`
owned by root. Leave that one alone; the MariaDB image chowns its own data directory and refuses
one somebody claimed first. `uploads` is the half of this install a dump cannot rebuild, the
originals and every resized variant. `tmp` and `logs` are working space, not state.

## 3. Secrets

Three, all generated here. `APP_KEY` is the Laravel application key and the container refuses to
boot without one decoding to exactly 32 bytes. The other two are the `lychee` database user's
password and the MariaDB root password. Lychee ships no account and no admin token, so the admin
is created in the browser in step 7. Print none of the three, in chat, summary or log.

```bash
umask 077
cat > /srv/lychee/.env <<EOF
APP_URL=https://<DOMAIN>
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> /srv/lychee/.env
chmod 600 /srv/lychee/.env
umask 022
ls -l /srv/lychee/.env
```

Replace `<DOMAIN>` there with the real hostname first. Assert: mode `-rw-------`, owned by the
login user. Compose reads this file for the `${...}` substitutions in compose.yml and never
mounts it. Hex for the database passwords: upstream warns a `DB_PASSWORD` carrying punctuation
has to be quoted, and one without cannot be quoted wrong.

## 4. compose.yml

```bash
cat > /srv/lychee/compose.yml <<'EOF'
# Lychee · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker guide ..... https://lycheeorg.dev/docs/getting-started/docker/
#   compose template . https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker-compose.yaml
#   entrypoint ....... https://github.com/LycheeOrg/Lychee/blob/v7.7.2/docker/scripts/entrypoint.sh
#
# Lychee plus the MariaDB holding albums, users, tags and photo metadata.
# MariaDB because upstream's README compose and the DB_CONNECTION default both
# say mysql; the image is the FrankenPHP build on the plain version tag, not a
# -legacy one. Every ${...} comes from /srv/lychee/.env, mode 600, which
# Compose reads and never mounts. Digests read from the registries on
# 2026-08-14; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: lychee-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: lychee
      MARIADB_USER: lychee
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/lychee/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  lychee:
    image: lycheeorg/lychee:v7.7.2@sha256:daacbba4876b3b73e4d46be1f4858f43cb2256c9c506c0ab7f333a8d9c993c00
    container_name: lychee
    restart: unless-stopped
    environment:
      # No APP_KEY, no boot: the entrypoint checks it decodes to 32 bytes.
      APP_KEY: ${APP_KEY}
      # Every album link and image URL is built from APP_URL. Caddy terminates
      # TLS and speaks plain http here, so the scheme is forced, not guessed.
      APP_URL: ${APP_URL}
      APP_FORCE_HTTPS: "true"
      APP_ENV: production
      APP_DEBUG: "false"
      TIMEZONE: UTC
      DB_CONNECTION: mysql
      DB_HOST: db
      # The entrypoint waits on this port with nc, so it is never left unset.
      DB_PORT: "3306"
      DB_DATABASE: lychee
      DB_USERNAME: lychee
      DB_PASSWORD: ${DB_PASSWORD}
      # sync: the request that uploads a photo also builds its thumbnails.
      # database would queue that for a worker this file does not run, and
      # Octane cuts a request at 30s by default, that upload's real ceiling.
      QUEUE_CONNECTION: sync
      LYCHEE_MAX_EXECUTION_TIME: "180"
      # The entrypoint moves its www-data to these before dropping privileges,
      # so the login user owns the photo files.
      PUID: ${PUID}
      PGID: ${PGID}
    volumes:
      # uploads is the half of the backup a database dump cannot rebuild.
      - /srv/lychee/uploads:/app/public/uploads
      - /srv/lychee/logs:/app/storage/logs
      - /srv/lychee/tmp:/app/storage/tmp
    healthcheck:
      # /up answers 200 before any account exists, which the app root does not.
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8000/up || exit 1"]
      start_period: 60s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: Caddy on this host alone reaches 8195.
      - "127.0.0.1:8195:8000"
    depends_on:
      db:
        condition: service_healthy
EOF
cd /srv/lychee && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. No database port is published, and no credential is written here.

## 5. Caddy and TLS

Append the block below, with `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-lychee
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Lychee · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://lycheeorg.dev/docs/getting-started/docker/ and
# https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, and every album link Lychee prints is built from it.

<DOMAIN> {
	encode zstd gzip

	# Lychee sends X-Content-Type-Options and Referrer-Policy itself. This
	# block adds only what belongs to whatever terminates TLS: HSTS, which
	# Lychee leaves off because it cannot know it is behind a certificate.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		-Server
	}

	# 8195 is the loopback port compose publishes here, not a container port
	# and not open in the firewall.
	reverse_proxy 127.0.0.1:8195
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-lychee, reload, and
report the objection. Caddy gets the certificate on first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp is
HTTP/3. 8195 is on loopback and 3306 is never published, so neither has a host port to firewall.
Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, nothing else.

## 7. Start and verify

The first start migrates the database and caches config, routes and views. Read this block to the
end first: there is a race in the middle of it.

```bash
cd /srv/lychee
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/up | grep -c 'Lychee is up'
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/install/admin | grep -c 'Set up admin account'
```

Assert all four, printing what you received. The loop ends on `200`. The grep prints above `0`,
`Lychee is up` being the heading the health page renders. The third prints
`307 https://<DOMAIN>/install/admin`, Lychee sending every page to the setup form until an
administrator exists. The last prints `1`, the form itself. On any miss, stop and run
`docker compose logs --tail 40 lychee` and `--tail 20 db`: a database never reporting healthy is
step 2, `APP_KEY is not set` is step 3, `502` is step 5. A running container is not success.

That `307` is the security problem here, and it has a clock on it. The setup form is
unauthenticated by necessity, there being no account yet to authenticate against, and it stays
open to whoever reaches the hostname until somebody submits it. First to submit owns this
gallery. The image carries a create-admin helper reading `ADMIN_USER`, and the entrypoint at this
tag never runs it, so the browser form is the only door.

STOP: tell the user to open https://<DOMAIN>/install/admin now, fill in a username and a password
twice, and press Create admin account, and wait. Do not continue until they confirm. That page
carries the browser title `Lychee Installer` and the words `Set up admin account.` over three
fields, and ends on `Admin account has been created.` Tell them it is the only credential this
gallery has, that nothing here relays mail so there is no password reset, and that it belongs in
their password manager before they press the button.

Once they confirm, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/install/admin
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

Assert both, printing what you received. The first prints `403`: the setup route carries a guard
throwing `Admin User has already been set` once an administrator exists, and that is the closure
assert for this install. The second prints `200`, the gallery rather than a redirect. If the
first is anything but `403`, stop and say so rather than reporting success: no account was made
and the form is still open. Self-registration is already shut, at `user_registration_enabled` 0.

## 8. First backup and restore

Two artifacts: a dump holding albums, tags, users, access rights and photo metadata, and an
archive holding the photos plus the configuration that rebuilds the service around them.

```bash
cd /srv/lychee
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/lychee/backups/lychee-db-$(date +%F).sql.gz
sudo tar -czf /srv/lychee/backups/lychee-files-$(date +%F).tar.gz -C /srv/lychee compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/lychee/backups/
```

Assert: both exist, both non-empty, both sizes printed. Nothing goes offline, because
`--single-transaction` snapshots a running InnoDB database. `uploads` goes in whole: Lychee does
not rebuild its variants on demand, so originals alone restore broken thumbnails.

A backup on the same disk is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/lychee
scp vps:/srv/lychee/backups/* ~/backups/lychee/
```

To restore: `docker compose down`, `sudo rm -rf /srv/lychee/mariadb /srv/lychee/uploads`,
recreate both as step 2 does, untar the archive into /srv/lychee so `.env` and the photos are
back before anything starts, `docker compose up -d db`, wait 30 seconds for healthy, pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`. Order matters: MariaDB reads its password from `.env` when it
initialises an empty directory, and a dump without the photos leaves albums listing nothing.

## 9. Updating later

Versions are listed at https://github.com/LycheeOrg/Lychee/releases and the tags carrying them at
https://hub.docker.com/r/lycheeorg/lychee/tags. Ignore any tag ending in `-legacy`: the older
nginx and php-fpm build, deprecated upstream, mounting different paths. Back up first, then edit
the lychee image line to the new tag and digest:

```bash
cd /srv/lychee
docker compose pull
docker compose up -d
docker compose logs --tail 40 lychee
```

The entrypoint runs `php artisan migrate --force` on every start, so watch until the migration
lines stop, then re-run step 7's checks. Sessions live inside the container, so this signs
everyone out once.

## 10. What will probably go wrong

The first upload will look like it has hung, and I nearly killed the container over it. There is
no worker in this stack, so `QUEUE_CONNECTION` is `sync`: the same request that carried the photo
up also decodes it, reads its EXIF and writes every resized variant before answering. A large
file off a modern camera can sit there most of a minute, and Octane's own default would have cut
it off at thirty seconds, which is why compose.yml raises `LYCHEE_MAX_EXECUTION_TIME` to 180.
Upload one photo and watch `docker compose logs -f lychee` rather than the progress bar.

## 11. Out of scope

- Do not add the worker container or switch `QUEUE_CONNECTION` to `database`. That is a third
  service, and this prompt backs up and checks two.
- Do not configure SMTP. Mail buys password reset here, and that is a second install.
- Do not configure OAuth, LDAP or WebAuthn. Each needs a client registered with somebody else,
  and step 7's account is the credential this install is built around.
- Do not add the facial-recognition or NSFW-classification containers from upstream's template.
  Both pull separate images, and neither is in this prompt's backup.
