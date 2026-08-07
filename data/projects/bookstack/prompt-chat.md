This path is slower: you paste every command yourself, and there is nobody watching the
output but you. If you can run Claude Code, use the other tab.

You are installing BookStack 26.05.3 on a VPS where Prompt Zero is done: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps`
unless a step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already
points at the box, and `<ADMIN_EMAIL>` with the address you want to sign in as.

Read this before step 1. `<DOMAIN>` becomes `APP_URL`, and BookStack builds every link it
stores and every link it prints from that one value. Changing it after you have written pages
is not a config edit, it is a command that rewrites URLs across the database. Pick the
hostname you intend to keep.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `1024` MB available, at least `5` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a
minute, run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that
does not resolve, and failed attempts count against a rate limit you cannot see. An IP that is
not your server's usually means a proxying CDN sits in front of the record; turn that off for
this hostname while you install, because the certificate would otherwise be issued to
somebody else's edge. Under 1024 MB free is the one you should not argue with: PHP-FPM and
MariaDB in the same box is where a 1 GB VPS starts swapping.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/bookstack /srv/bookstack/backups /srv/bookstack/config
sudo install -d -m 700 /srv/bookstack/mariadb
ls -la /srv/bookstack
```

You should see: `backups` and `config` owned by you, and `mariadb` at mode `drwx------` owned
by root.

If you do not: leave `mariadb` owned by root on purpose. The MariaDB image chowns its own data
directory the first time it starts, and one you have already chowned to yourself makes it
refuse to initialise. `config` is the other half of the wiki and it does belong to you: every
image someone pastes into a page, every file attachment and every theme lands under it.

## 3. Secrets

Four secrets: the application key, the database password, the MariaDB root password, and the
administrator's password. All four are generated here, on the server, and go straight into a
file only you can read. The last two lines add your own uid and gid, which the image uses to
keep `config` yours rather than adopting it as uid 911.

```bash
umask 077
cat > /srv/bookstack/.env <<EOF
APP_URL=https://<DOMAIN>
ADMIN_EMAIL=<ADMIN_EMAIL>
APP_KEY=base64:$(openssl rand -base64 32)
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
printf 'PUID=%s\nPGID=%s\n' "$(id -u)" "$(id -g)" >> /srv/bookstack/.env
chmod 600 /srv/bookstack/.env
umask 022
ls -l /srv/bookstack/.env
```

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>`
and `<ADMIN_EMAIL>` on the first two lines with your real values before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/bookstack/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all four values, which is fine before the database exists and a problem afterwards: MariaDB
keeps the password it was created with, and BookStack cannot decrypt old data under a new
`APP_KEY`.

Do not paste that file, any of those four values, or any command output containing them into
this chat window. The agent path never sees them; this path will hand them to a third party
unless you keep them out. Read your own password later with
`sudo grep ADMIN_PASSWORD /srv/bookstack/.env` in a terminal, not here. One more place two of
them live: compose.yml hands `ADMIN_EMAIL` and `ADMIN_PASSWORD` to the container environment
for step 7's command, where `docker inspect bookstack` can read them afterwards, the same
boundary as the file itself on a box where the docker group is root-equivalent.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/bookstack/compose.yml <<'EOF'
# BookStack · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   installation ... https://www.bookstackapp.com/docs/admin/installation/
#   configuration .. https://github.com/BookStackApp/BookStack/blob/v26.05.3/.env.example.complete
#   image docs ..... https://docs.linuxserver.io/images/docker-bookstack/
#
# BookStack ships no Docker image of its own; its installation page points at
# community docker setups. This file uses the LinuxServer.io one, GPL-3.0,
# which unpacks BookStack's own 26.05.3 release archive onto their Alpine plus
# nginx base image. The application is upstream's, the packaging is not.
#
# Two services: BookStack and the MariaDB holding every shelf, book, chapter
# and page. Every ${...} comes from /srv/bookstack/.env, mode 600, which
# Compose reads and never mounts. Digests read 2026-08-06; both are multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: bookstack-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: bookstack
      MARIADB_USER: bookstack
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/bookstack/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  bookstack:
    image: lscr.io/linuxserver/bookstack:version-v26.05.3@sha256:7f0af07baa41fd6265f5ec57887564d85be03a326f79cb32f926fe735e5313ff
    container_name: bookstack
    restart: unless-stopped
    environment:
      # The image's own `abc` user is remapped to these, so config/ is yours.
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: Etc/UTC
      # Every URL BookStack builds comes from this one value, so it carries the
      # https Caddy terminates rather than the plain http the container speaks.
      APP_URL: ${APP_URL}
      # Session and at-rest key. The image halts its init without one.
      APP_KEY: ${APP_KEY}
      DB_HOST: db
      DB_PORT: "3306"
      DB_DATABASE: bookstack
      DB_USERNAME: bookstack
      DB_PASSWORD: ${DB_PASSWORD}
      # Caddy terminates TLS. Upstream ships this false by default.
      SESSION_SECURE_COOKIE: "true"
      # Trust the proxy: the audit log then names the reader, not Caddy.
      APP_PROXIES: "*"
      # Neither is a BookStack setting; the application ignores both. They
      # let step 7 hand them to the console command that replaces the account
      # the first migration seeds, without either value reaching
      # a command line or the host's process list.
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
    volumes:
      - /srv/bookstack/config:/config
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/status || exit 1"]
      start_period: 30s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: Caddy alone reaches 8150; the container listens on 80.
      - "127.0.0.1:8150:80"
    depends_on:
      db:
        condition: service_healthy
EOF
cd /srv/bookstack && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `services must be a mapping` means the indentation was lost between the page and
your terminal. Run `rm /srv/bookstack/compose.yml` and paste again in one go. A warning that
`PUID` or `APP_KEY` is not set means you are not in /srv/bookstack, or step 3 did not write the
file; Compose reads `.env` from the directory you run it in, which is why every command in this
prompt starts with `cd /srv/bookstack`.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-bookstack
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# BookStack · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.linuxserver.io/images/docker-bookstack/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is also APP_URL in .env, and BookStack
# builds every link it stores from APP_URL, so moving it is a database edit.

<DOMAIN> {
	encode zstd gzip

	# BookStack sets its own content-security and frame-ancestors headers.
	# These four are the ones a reverse proxy is the right place for.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8150 is the loopback port compose publishes here, not a container
	# port and not open in the firewall. Caddy sets X-Forwarded-For, and
	# APP_PROXIES in compose.yml lets BookStack read it.
	reverse_proxy 127.0.0.1:8150
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-bookstack /etc/caddy/Caddyfile`,
reload, and paste again. The usual cause is a `<DOMAIN>` you forgot to replace, which Caddy
reads as a site name containing angle brackets. Caddy requests the certificate on the first
request that arrives for the hostname and renews it on its own, so there is nothing to
schedule and nothing to renew by hand.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8150` or `3306`.

If you do not: delete anything for `8150` or `3306` with `sudo ufw delete allow 8150`. 8150 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. 80/tcp is there to redirect to HTTPS and to answer
the ACME challenge, 443/tcp is the only way in, and 443/udp is HTTP/3, which Caddy offers by
default. `Status: inactive` is a different problem: Prompt Zero left this firewall enabled, so
something has turned it off since, and `sudo ufw enable` puts it back before you go further.

## 7. Start and verify

Read this before you paste. BookStack's first database migration inserts an administrator with
the email `admin@admin.com` and the password `password`, and the image's install notes publish
that pair. From the moment the schema exists until the console command below runs, that is a
known credential on a hostname that already resolves. Run this block in one sitting.

```bash
cd /srv/bookstack
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/status
docker compose exec -T --user abc bookstack sh -c 'php /app/www/artisan bookstack:create-admin --initial --no-ansi --name="Site administrator" --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD"'
curl -sS https://<DOMAIN>/login | grep -c 'list-heading">Log In<'
```

You should see, in order: the loop climbing to `200`, then
`{"database":true,"cache":true,"session":true}`, then
`The default admin user has been updated with the provided details!`, then `1`.

If you do not: the console line is the one to read carefully. That exact sentence means the
command found the seeded `admin@admin.com` account and rewrote its name, email and password in
place. `Admin account with email ... successfully created!` instead means it did not find that
account and made a second administrator, which leaves the first one alone and is not what you
want; stop and check whether an earlier attempt already changed it. If the loop never reaches
`200`, run `docker compose logs --tail 20 db` first, because a database that never reports
healthy is step 2 done wrong, and `docker compose logs --tail 60 bookstack` second. A `502`
that never clears means Caddy is reaching nothing on 8150.

Now prove the published credential is dead. This works from the server or from your own
machine:

```bash
shipped=password
jar=$(mktemp)
tok=$(curl -sS -c "$jar" https://<DOMAIN>/login | sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' | head -1)
echo "csrf token length ${#tok}"
curl -sS -b "$jar" -c "$jar" -L -d "_token=$tok" -d "email=admin@admin.com" -d "password=$shipped" https://<DOMAIN>/login | grep -c 'These credentials do not match our records'
rm -f "$jar"
unset shipped
```

You should see: a token length that is not `0`, then `1`.

If you do not: `1` means BookStack rejected the old pair with its own wording for a bad
sign-in, and that is the check that decides whether this install is safe to leave running. A
`0` means either the login succeeded, which is the bad case, or the request never got as far as
the password check. A token length of `0` tells you which: it means the page did not hand you a
CSRF token, so the attempt proved nothing and you should run the block again. If the token was
real and the count is `0`, the shipped password still works. Stop there, do not put anything in
the wiki, and re-run the console command from the previous block.

The first screen at https://<DOMAIN>/login shows the heading `Log In` above an `Email` field, a
`Password` field and a `Log In` button. A running container is not success; those two asserts
are.

Read your password once with `sudo grep ADMIN_PASSWORD /srv/bookstack/.env` and put it in your
password manager, then sign in at https://<DOMAIN>/login with the address you used for
`<ADMIN_EMAIL>`. There is no password-reset mail on this install, so that password manager
entry is the only copy you have.

## 8. First backup and restore

Two artifacts. The dump holds every shelf, book, chapter, page and revision. The config archive
holds the uploaded images and attachments plus the three files that rebuild the service around
them, including the application key without which nothing encrypted in the dump comes back.

```bash
cd /srv/bookstack
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/bookstack/backups/bookstack-db-$(date +%F).sql.gz
sudo tar -czf /srv/bookstack/backups/bookstack-config-$(date +%F).tar.gz -C /srv/bookstack compose.yml .env config -C /etc/caddy Caddyfile
ls -lh /srv/bookstack/backups/
```

You should see: two files, the dump a few tens of kilobytes on a fresh install and the archive
a little larger. Nothing goes offline while this runs.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read the
error; the usual one is that the database container is not up.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/bookstack
scp vps:/srv/bookstack/backups/* ~/backups/bookstack/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/bookstack/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the `vps` alias Prompt Zero created
lives.

Now prove the restore, today, while the only thing at risk is an empty wiki:

```bash
cd /srv/bookstack
docker compose down
sudo rm -rf /srv/bookstack/mariadb
sudo install -d -m 700 /srv/bookstack/mariadb
docker compose up -d db
sleep 40
gunzip -c /srv/bookstack/backups/bookstack-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/status
```

You should see: no output from the `gunzip` pipeline, then
`{"database":true,"cache":true,"session":true}` from the last command.

If you do not: `Access denied for user` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. If you ever restore onto a
different machine, put `.env` back before you start anything, because MariaDB reads
`DB_PASSWORD` from it the moment it initialises an empty directory and the `APP_KEY` in it is
the only key that decrypts what the dump carries.

## 9. Updating later

Application versions are listed at https://github.com/BookStackApp/BookStack/releases and the
image tags carrying them at https://github.com/linuxserver/docker-bookstack/tags. Take both
backups first, then edit the bookstack `image:` line in /srv/bookstack/compose.yml to the new
tag and its digest.

```bash
cd /srv/bookstack
docker compose pull
docker compose up -d
docker compose logs --tail 40 bookstack
```

You should see: migration output, then the server starting, and no repeating restart.

If you do not: put the old tag and digest back and run the same three commands. Then re-run
the status check from step 7 before you call the update done. The image runs the schema
migration on every start, so a version bump migrates the database on its own; what that also
means is that rolling back to an older image after a migration has run is not something the
database will forgive, which is why the backup comes first.

## 10. What will probably go wrong

The container will sit there `Up` and answer nothing, and `docker ps` will tell you everything
is fine. Mine did, for four minutes, before I read the log. The image checks for an application
key before anything else, and when it finds none it prints
`The application key is missing, halting init!` and then sleeps forever instead of exiting, so
the container never restarts and never looks broken. If step 7's loop stays on `502` or `000`,
run `docker compose logs --tail 40 bookstack` and look for that line first: `APP_KEY` did not
reach the container, which is step 3 or a `docker compose` run from the wrong directory.

## 11. Out of scope

- Do not configure SMTP. The wiki works without it; mail buys password resets, invitations and
  page-watch notifications, and that is a second install to do properly.
- Do not enable public registration. It is off in BookStack's defaults, and turning it on puts
  a sign-up form on a public hostname.
- Do not configure LDAP, SAML or OIDC. Those replace the account step 7 secured, and one
  half-configured locks you out of your own wiki.
- Do not switch storage to S3 or turn on the queue worker. Local files and synchronous jobs
  are the choice here, and both add a part this prompt does not back up.
