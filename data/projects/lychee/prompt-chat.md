This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Lychee 7.7.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the box.

Read this before step 1. `<DOMAIN>` becomes `APP_URL`, and Lychee builds every album link and
every image URL from that value, so the hostname you pick is the one on every link you hand out.
Read step 7 to the end before you run it: there is a window in the middle where the setup form is
open to anyone who reaches the address, and it closes only when you have filled it in.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
id -u
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, a number
of 1000 or thereabouts, and your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
and run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname nobody
resolves and failed attempts count against a rate limit you cannot see. The 2048 MB is real: the
app image is PHP 8.5 under FrankenPHP with ImageMagick and ffmpeg inside it, and MariaDB wants
its own on top. If `id -u` printed `0` you are root, and the container's start-up script rejects
any `PUID` outside 33 to 65534; log in as your normal user and start again.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/lychee /srv/lychee/backups /srv/lychee/uploads /srv/lychee/logs /srv/lychee/tmp
sudo install -d -m 700 /srv/lychee/mariadb
ls -la /srv/lychee
```

You should see: `backups`, `uploads`, `logs` and `tmp` owned by you, and `mariadb` at mode
`drwx------` owned by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts and refuses one somebody else has claimed. `uploads` is the
half of this install a database dump cannot rebuild: your originals and every resized variant
Lychee makes from them. `tmp` holds upload chunks while a photo is being processed and `logs`
holds the application log, so neither is worth archiving.

## 3. Secrets

Three secrets, all generated here on the server and written straight into a file only you can
read. `APP_KEY` is Laravel's application key, and the container refuses to start without one that
decodes to exactly 32 bytes. The other two are the password for the `lychee` database user and
the MariaDB root password. Lychee ships no account and no admin token, so the administrator is
the one you create in the browser in step 7.

Replace `<DOMAIN>` in the first line with your real hostname before you paste this.

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

You should see: mode `-rw-------`, your own username as owner, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if you
pasted the lines into different shells. Run `chmod 600 /srv/lychee/.env` and carry on. If the file
already existed from an earlier attempt, this block has now replaced all three values, which is
fine before the database exists and a problem afterwards: MariaDB keeps the password it was
created with, so a changed `DB_PASSWORD` against an existing directory produces an access-denied
error that never mentions passwords.

Do not paste that file, any of the three values, or any command output containing them into this
chat window. Nothing in this install ever asks you to read them out: Compose reads the file itself
for the `${...}` substitutions in step 4, and no browser form here wants a database password.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `variable is not set` names a line missing from /srv/lychee/.env, so go back to
step 3. A YAML error with a line number usually means the paste was truncated; `wc -l
/srv/lychee/compose.yml` should print a number in the eighties. No database port is published
here, and no credential is written here either: every value arrives from .env.

## 5. Caddy and TLS

Replace `<DOMAIN>` with your hostname in the block below before pasting it. The first line copies
the existing Caddyfile, because a syntax error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from the reload.

If you do not: restore the copy with
`sudo cp /etc/caddy/Caddyfile.before-lychee /etc/caddy/Caddyfile`, reload, and read what validate
objected to. The usual cause is a `<DOMAIN>` left literal in the site line. Caddy asks for the
certificate on the first request to the hostname and renews it on its own; there is nothing to
schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active` and rules for 80/tcp, 443/tcp and 443/udp, and nothing about
8195 or 3306.

If you do not: on a box Prompt Zero configured these three change nothing, and that is the
expected result. 8195 is bound to 127.0.0.1 in compose.yml and 3306 is never published at all, so
neither has a host port a firewall rule could apply to. If either appears in the output, remove
it: `sudo ufw delete allow 8195`.

## 7. Start and verify

The first start migrates the database and caches the config, routes and views, so give it a
minute before concluding anything.

```bash
cd /srv/lychee
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/up); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/up | grep -c 'Lychee is up'
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://<DOMAIN>/
curl -sS https://<DOMAIN>/install/admin | grep -c 'Set up admin account'
```

You should see, in order: the loop reaching `200`, then a number above `0`, then
`307 https://<DOMAIN>/install/admin`, then `1`.

If you do not: the `307` is the one worth understanding. Lychee redirects every page to its admin
setup form until an administrator exists, so a redirect at the root is correct rather than broken.
If the loop never reaches `200`, run `docker compose logs --tail 20 db` first, because a database
that never reports healthy is step 2 done wrong, and `docker compose logs --tail 40 lychee`
second; `APP_KEY is not set` there sends you back to step 3. A lasting `502` is step 5. A
container that says `Up` proves nothing on its own.

That `307` is also the security problem in this install, and it has a clock on it. The setup form
has to be unauthenticated, because there is no account yet to authenticate against, and it stays
open to anyone who reaches your hostname until somebody submits it. Whoever submits it first is
the administrator of your gallery. There is no way around it from the shell: the image carries a
create-admin helper that reads `ADMIN_USER` and `ADMIN_PASSWORD`, and the entrypoint in this
version never runs it. Do the next paragraph now, not tomorrow.

Open https://<DOMAIN>/install/admin in your browser. The page has the browser title
`Lychee Installer` and the words `Set up admin account.` above three fields: Username, Password
and Confirm password. Fill them in and press `Create admin account`. That account is the only
credential this gallery has and no mail is relayed from this install, so there is no password
reset and it goes in your password manager before you press the button.

You should see: `Admin account has been created.` and an `Open Lychee` link.

If you do not: a complaint under the Password field is the password rule, so try a longer one. A
page that reloads with `Admin User has already been set` means somebody got there first, and on a
brand new install that somebody is almost certainly your own earlier browser tab; log in with the
credentials you used there. If it was not you, take the stack down with `docker compose down`,
delete /srv/lychee/mariadb, and start step 7 again on a hostname nobody has been given yet.

Now prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/install/admin
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/
```

You should see, in order: `403`, then `200`.

If you do not: the `403` is the one that matters. Lychee's setup route carries a guard that throws
`Admin User has already been set` once an administrator exists, and that 403 is your proof the
form is no longer a way in. A `307` there means no account was created and the form is still open
to the internet, so go back and create it. The `200` on the root is the gallery itself, now that
the redirect to the setup form is gone. Self-registration is a separate door and it is already
shut: Lychee ships `user_registration_enabled` set to `0` and nothing here changes it.

## 8. First backup and restore

Two artifacts. The dump holds the albums, tags, users, access rights and every photo's metadata.
The file archive holds the photos and the configuration that rebuilds the service around them.

```bash
cd /srv/lychee
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/lychee/backups/lychee-db-$(date +%F).sql.gz
sudo tar -czf /srv/lychee/backups/lychee-files-$(date +%F).tar.gz -C /srv/lychee compose.yml .env uploads -C /etc/caddy Caddyfile
ls -lh /srv/lychee/backups/
```

You should see: two files, the dump a few tens of kilobytes and the archive small on a fresh
install, because the only photos in it are the ones you have not uploaded yet. Nothing goes
offline: `--single-transaction` snapshots a running InnoDB database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump` failed
and the shell created the file anyway. Run that line again without `| gzip` to read the error.
`logs` and `tmp` are left out of the archive on purpose. `uploads` goes in whole rather than
originals only, because Lychee does not rebuild its resized variants on demand and an archive of
originals alone would restore a gallery of broken thumbnails.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not the
server:

```bash
mkdir -p ~/backups/lychee
scp vps:/srv/lychee/backups/* ~/backups/lychee/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/lychee/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty gallery:

```bash
cd /srv/lychee
docker compose down
sudo rm -rf /srv/lychee/mariadb /srv/lychee/uploads
sudo install -d -m 700 /srv/lychee/mariadb
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/lychee/uploads
sudo tar -xzf /srv/lychee/backups/lychee-files-$(date +%F).tar.gz -C /srv/lychee compose.yml .env uploads
docker compose up -d db
sleep 30
gunzip -c /srv/lychee/backups/lychee-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/install/admin
```

You should see: no output from the restore itself, then `403` from the last line, which means your
administrator account came back from a database and a directory that were both deleted.

If you do not: `Access denied for user 'lychee'` means the archive did not restore `.env` before
MariaDB initialised its empty directory, so MariaDB invented a different password. Repeat the
block and check the tar step runs before `docker compose up -d db`. A `307` from the last line
means the dump did not load, so your account is gone and the setup form is open again: rerun the
`gunzip -c` line and read its error. That ordering is the whole lesson, and the photos are the
other half of it: restore the dump without `uploads` and every album lists files that are not
there.

## 9. Updating later

New versions are listed at https://github.com/LycheeOrg/Lychee/releases and the tags carrying them
at https://hub.docker.com/r/lycheeorg/lychee/tags. Ignore any tag ending in `-legacy`: that is the
older nginx and php-fpm build, which upstream's Docker guide marks deprecated and which mounts
different paths inside the container. Take both backup artifacts first, then edit the lychee image
line in /srv/lychee/compose.yml to the new tag and its digest.

```bash
cd /srv/lychee
docker compose pull
docker compose up -d
docker compose logs --tail 40 lychee
```

You should see: migration lines going past, then the server reporting itself ready.

If you do not: the entrypoint runs the database migration on every start, so an error there is the
one to read rather than anything on the web page. Re-run step 7's `/up` and root checks before
calling the update done. Two things will surprise you afterwards: sessions live inside the
container rather than a mounted directory, so recreating it signs you out and you log in again,
and the start-up permission sweep walks every file under `uploads`, which on a large library adds
minutes to a restart.

## 10. What will probably go wrong

Your first upload will look like it has hung, and I nearly killed the container over it. There is
no worker in this stack, so `QUEUE_CONNECTION` is `sync`: the same request that carried the photo
up also decodes it, reads its EXIF and writes every resized variant before it answers. A large
file off a modern camera can sit there for most of a minute with nothing moving in the browser,
and the server's own default would have cut it off at thirty seconds, which is why compose.yml
raises `LYCHEE_MAX_EXECUTION_TIME` to 180. Upload one photo, wait, and watch
`docker compose logs -f lychee` rather than the progress bar. If a batch of large files genuinely
times out, that is the point where the worker container becomes worth adding.

## 11. Out of scope

- Do not add the worker container or switch `QUEUE_CONNECTION` to `database`. That is a third
  service with its own restart loop, and this page backs up and checks two.
- Do not configure SMTP. Lychee works without mail, and what mail buys here is password reset,
  which is a second install to do properly.
- Do not configure OAuth, LDAP or WebAuthn. Each needs a client registered with somebody else,
  and the account you made in step 7 is the credential this install is built around.
- Do not add the facial-recognition or NSFW-classification containers from upstream's template.
  Both pull separate images, and neither is in the backup this page takes.
