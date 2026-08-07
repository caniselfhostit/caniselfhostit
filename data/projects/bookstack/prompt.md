You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install BookStack 26.05.3 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` becomes `APP_URL`, and BookStack builds every link it stores from that
value, so moving it later is a database edit. Its A record must already point here.
`<ADMIN_EMAIL>` is what the administrator signs in with; this install configures no mail, so
nothing is ever sent to it.

BookStack and its database need 1024 MB of RAM available and 5 GB free on /srv. Both images
publish amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 1024 MB or free disk is under 5 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name nobody resolves.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/bookstack /srv/bookstack/backups /srv/bookstack/config
sudo install -d -m 700 /srv/bookstack/mariadb
ls -la /srv/bookstack
```

Assert: `backups` and `config` owned by the login user, `mariadb` at mode `700` owned by root.
Leave that last one alone; the MariaDB image chowns its own data directory and refuses one
somebody claimed first. `config` is the other half of the wiki: uploaded images, attachments
and themes.

## 3. Secrets

Four secrets, generated here: the application key, the database password, the MariaDB root
password, and the administrator's password. Print none, and keep all four out of your summary
and every log line.

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

Assert: mode `-rw-------` and the login user's name twice. `APP_KEY` is 32 random bytes in the
`base64:` form BookStack's key generator emits, which is why openssl makes it here rather than
a helper that pulls an unpinned image. Tell the user, without printing anything, that this file
is now the most valuable object on the box: everything BookStack encrypts at rest uses it.

## 4. compose.yml

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

Assert: that prints `compose OK`. No database port is published and no credential is written
here; the account that arrives with a published password is closed in step 7.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy it first: a syntax error takes down every other site here.

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

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-bookstack, reload,
and report the objection. Caddy gets the certificate on the first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8150 is bound to 127.0.0.1 and 3306 is never published, so neither has a host port a
rule could apply to. Assert: `Status: active`, 80, 443/tcp and 443/udp, nothing else.

## 7. Start and verify

Read this first. BookStack's first migration inserts an administrator, `admin@admin.com` with
the password `password`, and the image's install notes publish that pair. Until the command
below runs it is a known credential on a hostname that already resolves, so run the whole block
in one go.

```bash
cd /srv/bookstack
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/status); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/status
docker compose exec -T --user abc bookstack sh -c 'php /app/www/artisan bookstack:create-admin --initial --no-ansi --name="Site administrator" --email="$ADMIN_EMAIL" --password="$ADMIN_PASSWORD"'
curl -sS https://<DOMAIN>/login | grep -c 'list-heading">Log In<'
```

Assert all four, printing what you received for each. The loop ends on `200`. The status
response is `{"database":true,"cache":true,"session":true}`. The console command prints
`The default admin user has been updated with the provided details!`, which is how you know it
rewrote the seeded account rather than adding a second administrator. The last one prints `1`.

Now prove the published credential is dead. Server or the user's machine:

```bash
shipped=password
jar=$(mktemp)
tok=$(curl -sS -c "$jar" https://<DOMAIN>/login | sed -n 's/.*name="_token" value="\([^"]*\)".*/\1/p' | head -1)
echo "csrf token length ${#tok}"
curl -sS -b "$jar" -c "$jar" -L -d "_token=$tok" -d "email=admin@admin.com" -d "password=$shipped" https://<DOMAIN>/login | grep -c 'These credentials do not match our records'
rm -f "$jar"
unset shipped
```

Assert: the token length is not `0` and the last line prints `1`. That is BookStack's own
wording for a rejected sign-in, and it is the security assert here. A zero-length token means
the attempt failed for a missing CSRF token rather than a wrong password, so treat it as a
failure too. If the count is `0` the old pair still works: stop, say so, and do not report
success. If any of the earlier four missed, stop, run `docker compose logs --tail 60 bookstack`
and `docker compose logs --tail 20 db`, and name the likely step: a database that never reports
healthy is step 2, a lasting `502` is step 5. A running container is not success.

The first screen at https://<DOMAIN>/login shows the heading `Log In` above an `Email` field, a
`Password` field and a `Log In` button.

STOP: tell the user to read their password with
`sudo grep ADMIN_PASSWORD /srv/bookstack/.env`, put it in their password manager, sign in at
https://<DOMAIN>/login with `<ADMIN_EMAIL>`, and wait. Do not continue until they confirm they
are on the empty shelves page. There is no password-reset mail here, so that entry is the only
copy.

## 8. First backup and restore

Two artifacts. The dump holds every shelf, book, chapter, page and revision. The config archive
holds the uploaded images and attachments plus the three files that rebuild the service around
them, including the key nothing encrypted in the dump comes back without.

```bash
cd /srv/bookstack
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/bookstack/backups/bookstack-db-$(date +%F).sql.gz
sudo tar -czf /srv/bookstack/backups/bookstack-config-$(date +%F).tar.gz -C /srv/bookstack compose.yml .env config -C /etc/caddy Caddyfile
ls -lh /srv/bookstack/backups/
```

Assert: both exist, both are non-empty, both sizes printed. Nothing goes offline: the tables
are InnoDB, so the dump snapshots consistently while the wiki serves.

A backup on the same disk is not a backup. Run this one from the user's machine, not the
server:

```bash
mkdir -p ~/backups/bookstack
scp vps:/srv/bookstack/backups/* ~/backups/bookstack/
```

To restore: `docker compose down`, `sudo rm -rf /srv/bookstack/mariadb /srv/bookstack/config`,
recreate both as step 2 does, untar the config archive into /srv/bookstack so `.env` and
`config` are back before anything starts, `docker compose up -d db`, wait 30 seconds for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`. Tell the user why `.env` comes back first: MariaDB reads its
password from it when it initialises an empty directory, and its `APP_KEY` is the only key
that decrypts the dump.

## 9. Updating later

Versions are listed at https://github.com/BookStackApp/BookStack/releases and the image tags
carrying them at https://github.com/linuxserver/docker-bookstack/tags. Take both backups first,
then edit the bookstack image line in compose.yml to the new tag and digest:

```bash
cd /srv/bookstack
docker compose pull
docker compose up -d
docker compose logs --tail 40 bookstack
```

The image runs the schema migration on every start, so a version bump migrates the database
itself. Watch that log until it settles, then re-run step 7's status check.

## 10. What will probably go wrong

The container will sit there `Up`, answer nothing, and `docker ps` will tell you everything is
fine. Mine did, for four minutes, before I read the log. The image checks for an application
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
  half-configured locks the user out of their own wiki.
- Do not switch storage to S3 or turn on the queue worker. Local files and synchronous jobs
  are the choice here, and both add a part this prompt does not back up.
