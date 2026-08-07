You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Leantime 3.9.8 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server. It becomes `LEAN_APP_URL`, the base every
Leantime redirect is built against, so changing it later means editing .env and restarting.

Leantime needs 2048 MB of RAM available and 10 GB free on /srv. It is PHP-FPM behind nginx in
front of MySQL; both images publish amd64 and arm64. Measure all four first:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve, and failed attempts hit a rate limit.

## 2. Layout

The application image runs as `www-data`, uid 1000, so the two directories it writes to are
created owned by 1000:

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/leantime /srv/leantime/backups
sudo install -d -m 700 /srv/leantime/mysql
sudo install -d -m 750 -o 1000 -g 1000 /srv/leantime/userfiles /srv/leantime/public-userfiles
ls -la /srv/leantime
```

Assert: `ls -la` shows `backups` owned by the login user, `mysql` at mode `700`, and both
`userfiles` directories owned by uid 1000. Leave `mysql` alone: that image
chowns its own data directory on first start, and one already chowned refuses to initialise.

## 3. Secrets

Three secrets, all generated here: the MySQL root password, the `leantime` database user's
password, and `LEAN_SESSION_PASSWORD`, which salts every session cookie. Print none of them, keep
them out of your summary and out of every log line. Hex, not base64: Compose reads this file to
expand the `${...}` in compose.yml and treats an unquoted `#` as a comment, so a base64 secret
can lose its tail.

```bash
umask 077
cat > /srv/leantime/.env <<EOF
DOMAIN_NAME=<DOMAIN>
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
LEAN_SESSION_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/leantime/.env
umask 022
ls -l /srv/leantime/.env
```

Assert: the file exists with mode `-rw-------` and the login user's name twice. It is never
mounted into a container; Compose reads it on the host from /srv/leantime.
`LEAN_SESSION_PASSWORD` is not in the database, so a restore without this file signs everyone
out.

## 4. compose.yml

```bash
cat > /srv/leantime/compose.yml <<'EOF'
# Leantime · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install .... https://docs.leantime.io/installation/docker
#   variable reference  https://github.com/Leantime/docker-leantime/blob/master/sample.env
#   backup & restore .. https://docs.leantime.io/installation/backup-restore
#
# Two services: Leantime's nginx-and-PHP-FPM image and the MySQL holding every
# project, task, goal and comment. Upstream keeps its data in named volumes;
# this file binds the two userfiles directories the backup page asks you to
# keep under /srv/leantime, and leaves MySQL on a directory the image chowns
# for itself. No plugin mount: upstream asks for one only if you install
# marketplace plugins, and this install does not. The app image runs as
# www-data, uid 1000, so those two are created owned by 1000. Digests read
# 2026-08-07; both images have arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  leantime_db:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: leantime-db
    restart: unless-stopped
    command: --character-set-server=UTF8MB4 --collation-server=UTF8MB4_unicode_ci
    environment:
      MYSQL_DATABASE: leantime
      MYSQL_USER: leantime
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - /srv/leantime/mysql:/var/lib/mysql
    healthcheck:
      # Runs inside the container, where that value already is an env var.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u leantime -p$$MYSQL_PASSWORD --silent"]
      start_period: 30s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  leantime:
    image: leantime/leantime:3.9.8@sha256:6150dd3e8a1e17f1ead8d462d31e26177fe906ce3602dbbbf6af5417ef809de3
    container_name: leantime
    restart: unless-stopped
    # Both of these come from upstream's compose file for this service.
    security_opt:
      - no-new-privileges:true
    cap_add:
      - CAP_CHOWN
      - CAP_SETGID
      - CAP_SETUID
    environment:
      LEAN_DB_HOST: leantime_db
      LEAN_DB_PORT: "3306"
      LEAN_DB_DATABASE: leantime
      LEAN_DB_USER: leantime
      LEAN_DB_PASSWORD: ${DB_PASSWORD}
      # Salts every session. Change it later and everyone is signed out.
      LEAN_SESSION_PASSWORD: ${LEAN_SESSION_PASSWORD}
      # Caddy terminates TLS in front, so the base URL carries its scheme.
      # Upstream needs this set for proxy installs; without it /install loops.
      LEAN_APP_URL: https://${DOMAIN_NAME}
      # true because Caddy serves this over https.
      LEAN_SESSION_SECURE: "true"
      LEAN_DEFAULT_TIMEZONE: UTC
    volumes:
      - /srv/leantime/userfiles:/var/www/html/userfiles
      - /srv/leantime/public-userfiles:/var/www/html/public/userfiles
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8163.
      - "127.0.0.1:8163:8080"
    depends_on:
      leantime_db:
        condition: service_healthy
EOF
cd /srv/leantime && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, a database with no host
port. Do not add one.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-leantime
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Leantime · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.leantime.io/installation/docker and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also DOMAIN_NAME in .env, where it becomes LEAN_APP_URL: keep them identical.

<DOMAIN> {
	# The interface is HTML, JavaScript and JSON, and compresses well.
	encode zstd gzip

	# The image's own nginx already sends X-Frame-Options, a CSP and versions of
	# the three below. Caddy's header directive replaces rather than appends, so
	# a browser sees one of each and the two not named here pass through.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# 8163 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8163
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If it fails, restore
/etc/caddy/Caddyfile.before-leantime, reload, and report what it objected to. Caddy requests the
certificate on the first request and renews it on its own.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp redirects to HTTPS and answers the ACME challenge, 443/tcp is the only way in, 443/udp is
HTTP/3, 8163 stays closed because compose binds it to 127.0.0.1, and 3306 because compose never
publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule mentioning 8163 or 3306.

## 7. Start and verify

MySQL initialises first and the app container does not start until it reports healthy, so the
first minute answers `502` through Caddy. The image serves `/healthCheck.php` from nginx,
outside the application router, which is why the loop asks for that rather than a page.

```bash
cd /srv/leantime
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/healthCheck.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/healthCheck.php
curl -sS https://<DOMAIN>/install | grep -c 'This script will set up your database' || true
```

Assert all three and print what you received: the loop ends on `200`; the second prints `Ok` and
nothing else; the third prints `1`. On any miss, stop, run
`docker compose logs --tail 40 leantime` and `docker compose logs --tail 20 leantime_db`, and
name the earlier step. A `502` that never clears means the database never reported healthy, which
is step 2. A `0` next to a `200` means the app answered and redirected, which is `LEAN_APP_URL`
in step 3 disagreeing with the hostname in step 5. A running container is not success.

The first screen at https://<DOMAIN> redirects to https://<DOMAIN>/install: the heading
`Installation` over the line
`This script will set up your database and create an administrator account`, then boxes for
`Email`, `First name`, `Last name` and `Company Name`, and an `Install` button. There is no
default account and no default password here; the first one is what the user creates there.

STOP: tell the user to open https://<DOMAIN>/install, fill in that form, press `Install`, then
set a password on the `Setting Account Details` screen it hands them next. Upstream wants 8
characters with an uppercase, a lowercase, a number and a symbol. Tell them to put it in their
password manager: nothing here can mail it back. Wait. Do not continue until they confirm they
are signed in.

Now prove the installer closed behind them:

```bash
curl -sS https://<DOMAIN>/install | grep -c 'This script will set up your database' || true
curl -sSL https://<DOMAIN>/ | grep -c '<label for="password">Password</label>' || true
```

Assert both: the first prints `0` and the second prints `1`. That `0` is the security assert
here: Leantime stops serving the installer once the user table exists, so a `1` means no account
was created and the form is still open on a public hostname. Stop and send the user back to it.
The `1` is the login form answering at the root.

## 8. First backup and restore

Two artifacts. The database holds every project, task, goal, wiki page and comment. The file
archive holds the uploads and the files that rebuild the service around them.

```bash
cd /srv/leantime
docker compose exec -T leantime_db sh -c 'mysqldump --single-transaction --no-tablespaces -u leantime -p"$MYSQL_PASSWORD" leantime' | gzip > /srv/leantime/backups/leantime-db-$(date +%F).sql.gz
sudo tar -czf /srv/leantime/backups/leantime-files-$(date +%F).tar.gz -C /srv/leantime compose.yml .env userfiles public-userfiles -C /etc/caddy Caddyfile
ls -lh /srv/leantime/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database consistently, `--no-tablespaces` is
there because the `leantime` user is not a superuser, and the password is read inside the
database container so it never reaches the host process list.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/leantime
scp vps:/srv/leantime/backups/* ~/backups/leantime/
```

To restore, in this order. Untar the file archive into /srv/leantime first, so .env is back
before any container starts: MySQL takes its passwords from it the moment it initialises an empty
data directory, and a missing .env means a database that never starts. Then
`docker compose down`, `sudo rm -rf /srv/leantime/mysql`, recreate it as in step 2,
`docker compose up -d leantime_db`, wait a minute for healthy, then
`gunzip -c /srv/leantime/backups/leantime-db-<date>.sql.gz | docker compose exec -T leantime_db sh -c 'mysql -u leantime -p"$MYSQL_PASSWORD" leantime'`,
then `docker compose up -d`. Tell the user the stakes at 2am: the dump is the whole plan, the
uploads are only in the file archive, and `LEAN_SESSION_PASSWORD` is in .env alone.

## 9. Updating later

New versions are listed at https://github.com/Leantime/leantime/releases. Leantime ships several
in a busy month and each migrates its own schema, so back up both first, then edit the image
line in /srv/leantime/compose.yml to the new tag and digest:

```bash
cd /srv/leantime
docker compose pull
docker compose up -d
docker compose logs --tail 30 leantime
```

Watch that log until it settles, then re-run step 7's first two checks. If a version wants a
schema change it serves `/install/update` instead of the app; the user presses its button once.

## 10. What will probably go wrong

The first two minutes look like a broken reverse proxy. Compose holds the app container back
until MySQL reports healthy, MySQL is building its data directory from scratch, and until both
finish Caddy has nothing on 8163 to talk to, so every request returns `502 Bad Gateway`. I
read that as a Caddyfile mistake and restored /etc/caddy/Caddyfile from my own copy twice before
the health loop caught up on round nine. Let step 7's loop run all forty rounds; while
`docker compose ps` still shows `leantime-db` as `starting`, that `502` is the design working.

## 11. Out of scope

- Do not configure SMTP or set any `LEAN_EMAIL_` variable. Leantime runs with mail off: invitations
  and notifications go nowhere, and the admin hands new people their credentials directly.
- Do not enable LDAP or OIDC. Both need an identity provider this install does not have, and both
  change how the account from step 7 signs in.
- Do not install plugins from the Leantime marketplace. Some are paid extensions of this same
  install, a broken one takes the app down, and no volume is mounted to keep them.
- Do not set `LEAN_USE_S3`. Uploads belong on the two mounted directories step 8 backs up.
