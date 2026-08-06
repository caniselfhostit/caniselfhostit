You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Kimai 2.63.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. The A record for `<DOMAIN>` must already point at this server. `<ADMIN_EMAIL>` goes
on the first Kimai account, which signs in as `admin`, so it is an identifier, not a mailbox
this install writes to.

Kimai needs 2048 MB of RAM available and 10 GB free on /srv. It is PHP under Apache in front of
MySQL; both images publish amd64 and arm64. Measure all four first:

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

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/kimai /srv/kimai/backups
sudo install -d -m 700 /srv/kimai/mysql
sudo install -d -m 750 /srv/kimai/var
ls -la /srv/kimai
```

Assert: `ls -la` shows `backups` owned by the login user, `mysql` at mode `700` and `var`
present. Leave the last two alone. MySQL chowns its data directory on first start and Kimai
chowns /opt/kimai/var on every start, so after step 7 both belong to uids the images chose and
are read with sudo. Inside `var` sit the exports, invoices and plugins.

## 3. Secrets

Four secrets, all generated here: the MySQL root password, the MySQL password for the `kimai`
database user, `APP_SECRET`, and the password the container puts on the first admin account. Do
not print any of them, do not repeat them in your summary, and keep them out of every log.

Hex, not base64: the start-up script parses `DATABASE_URL` by splitting on `/`, `:` and `@` and
url-decoding the pieces, so any of those characters, or a `%`, breaks the wait-for-database loop
before Kimai runs.

```bash
umask 077
cat > /srv/kimai/.env <<EOF
DOMAIN_NAME=<DOMAIN>
ADMIN_EMAIL=<ADMIN_EMAIL>
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
APP_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 /srv/kimai/.env
umask 022
ls -l /srv/kimai/.env
```

Assert: the file exists with mode `-rw-------` and the login user's name twice. Docker Compose
reads it for the `${...}` substitutions in compose.yml whenever it runs from /srv/kimai, so it
is never mounted. `APP_SECRET` matters more than it looks: set here it lives in this file and
the backup; left out, the image writes one into a volume, and losing it invalidates every
session.

## 4. compose.yml

```bash
cat > /srv/kimai/compose.yml <<'EOF'
# Kimai · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker compose ... https://www.kimai.org/documentation/docker-compose.html
#   docker image ..... https://www.kimai.org/documentation/docker.html
#   backups .......... https://www.kimai.org/documentation/backups.html
#
# Two services: Kimai's Apache image and the MySQL holding every timesheet.
# Upstream supports MariaDB and MySQL only, so there is no SQLite path. Their
# example pins mysql:8.3, an innovation release out of support; 8.4 is the
# long-term line and DATABASE_URL says so. It also splits var/data from
# var/plugins, leaving invoices in an anonymous volume; this file mounts all of
# /opt/kimai/var, the path the image declares as a volume and the one the backup
# page asks you to keep. Digests read 2026-08-06; both images have arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  sqldb:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: kimai-db
    restart: unless-stopped
    command: --default-storage-engine innodb
    environment:
      MYSQL_DATABASE: kimai
      MYSQL_USER: kimai
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - /srv/kimai/mysql:/var/lib/mysql
    healthcheck:
      # Runs inside the container, where that value already is an env var.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u kimai -p$$MYSQL_PASSWORD --silent"]
      start_period: 30s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  kimai:
    image: kimai/kimai2:2.63.0@sha256:c0d55027c384b5f4e612dfeb326fdcff1d700dc469f85961b365eeb1c353119b
    container_name: kimai
    restart: unless-stopped
    environment:
      DATABASE_URL: "mysql://kimai:${DB_PASSWORD}@sqldb/kimai?charset=utf8mb4&serverVersion=8.4.0"
      APP_SECRET: ${APP_SECRET}
      # A regex Symfony matches the Host header against. 127.0.0.1 is in it
      # because the image's own HEALTHCHECK asks for that name.
      TRUSTED_HOSTS: localhost|127.0.0.1|${DOMAIN_NAME}
      # Caddy is on the host, so requests arrive from the docker bridge gateway.
      # Without these ranges Symfony ignores X-Forwarded-Proto and writes
      # http:// links on an https site.
      TRUSTED_PROXIES: 172.16.0.0/12,192.168.0.0/16,10.0.0.0/8
      # The start-up script creates the admin account while ADMINPASS is set.
      # Step 7 drops it from .env; `:-` keeps compose quiet once it is gone.
      ADMINMAIL: ${ADMIN_EMAIL}
      ADMINPASS: ${ADMIN_PASSWORD:-}
      memory_limit: 512M
    volumes:
      - /srv/kimai/var:/opt/kimai/var
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8126.
      - "127.0.0.1:8126:8001"
    depends_on:
      sqldb:
        condition: service_healthy
EOF
cd /srv/kimai && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, a database with no host
port at all. Do not add one: nothing outside this project speaks to it.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-kimai
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Kimai · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://www.kimai.org/documentation/docker-compose.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also DOMAIN_NAME in .env, where it becomes the TRUSTED_HOSTS pattern, so the
# two stay the same string.

<DOMAIN> {
	# The interface is HTML, JavaScript and JSON; exports arrive compressed.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: invoice templates are editable here, and one
	# written without testing them breaks an invoice.

	# 8126 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8126
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-kimai, reload, and report what it objected to. Caddy requests the
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
HTTP/3, 8126 stays closed because compose binds it to 127.0.0.1, and 3306 because compose never
publishes it. Assert: `ufw status verbose` prints `Status: active`, shows 80, 443/tcp and
443/udp, and no rule mentioning 8126 or 3306.

## 7. Start and verify

MySQL initialises, then Kimai's start-up script waits for it, builds the schema and creates one
account named `admin` with the password from step 3. First boot takes two to three minutes.

```bash
cd /srv/kimai
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/en/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/en/login | grep -o '<title>[^<]*</title>'
docker compose exec -T kimai /opt/kimai/bin/console kimai:user:list
```

Assert all three, and print what you received for each: the loop ends on `200`; the second
prints `<title>Kimai</title>`; the third prints a one-row table whose `Username` is `admin`,
whose `Roles` include `ROLE_SUPER_ADMIN` and whose `Active` reads `Yes`. If any of the three
misses, stop, run `docker compose logs --tail 40 kimai` and
`docker compose logs --tail 20 sqldb`, and name the likely earlier step: `502` means Caddy
reaches nothing on 8126, an empty user table means the container never saw `ADMIN_PASSWORD`, and
a script still printing `Wait for database connection` after five minutes points at step 2. A
running container is not success.

The first screen at https://<DOMAIN> redirects to https://<DOMAIN>/en/login, which shows the
wordmark `Kimai` over the line `Sign in to start your session`, a `Username` box, a `Password`
box and a `Sign In` button.

STOP: tell the user to read the password with `sudo grep ADMIN_PASSWORD /srv/kimai/.env`, put it
in their password manager, sign in at https://<DOMAIN> as `admin`, and confirm the dashboard
loads. Wait. Do not continue until they confirm: the next block deletes this server's copy.

Now close the bootstrap out. The start-up script runs under `bash -x`, so the account-creation
command, password included, was traced into the container log on first boot, and it repeats on
every restart while `ADMINPASS` still has a value:

```bash
cd /srv/kimai
sed -i '/^ADMIN_PASS/d' /srv/kimai/.env
docker compose up -d --force-recreate kimai
sleep 60
docker compose logs kimai | grep -c 'kimai:user:create' || true
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/en/login
```

Assert both: the count prints `0` and the status prints `200`. That `0` is the security assert
in this block. The old container was replaced and its log file went with it, so the traced
password is off the box, and the deleted `ADMIN_PASSWORD` line stops the script recreating the
account, and retracing it, on every start from here. A count above `0` means the edit did not
take: check `grep -c '^ADMIN_PASS' /srv/kimai/.env` and run the block again. The user's password
manager now holds the only copy; if they lose it, recovery is
`docker compose exec -it kimai /opt/kimai/bin/console kimai:user:password admin`, which asks on
the terminal rather than taking a password on a command line.

## 8. First backup and restore

Two artifacts. The database holds the customers, projects, timesheets and rates. The file
archive holds compose.yml, .env, the Caddy site block and `var`, where exports and invoices
live.

```bash
cd /srv/kimai
docker compose exec -T sqldb sh -c 'mysqldump --single-transaction --no-tablespaces -u kimai -p"$MYSQL_PASSWORD" kimai' | gzip > /srv/kimai/backups/kimai-db-$(date +%F).sql.gz
sudo tar -czf /srv/kimai/backups/kimai-files-$(date +%F).tar.gz -C /srv/kimai compose.yml .env var -C /etc/caddy Caddyfile
ls -lh /srv/kimai/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database consistently, and `--no-tablespaces`
is there because the `kimai` user is not a superuser and the dump fails without it. The password
is read inside the database container, so it never reaches the host process list.

A backup on the same disk is not a backup, so run this from the user's machine:

```bash
mkdir -p ~/backups/kimai
scp vps:/srv/kimai/backups/* ~/backups/kimai/
```

To restore, in this order. Untar the file archive into /srv/kimai first, so .env is back before
any container starts: MySQL takes its passwords from that file the moment it initialises an
empty data directory, and a missing .env means a blank password and a database that never
starts. Then `docker compose down`, `sudo rm -rf /srv/kimai/mysql`, recreate as in step 2,
`docker compose up -d sqldb`, wait a minute for healthy, then
`gunzip -c /srv/kimai/backups/kimai-db-<date>.sql.gz | docker compose exec -T sqldb sh -c 'mysql -u kimai -p"$MYSQL_PASSWORD" kimai'`,
then `docker compose up -d`. Tell the user what matters at 2am: an hour they billed and cannot
prove is an hour they do not get paid for, so the dump is the invoice, not the app.

## 9. Updating later

New versions are listed at https://github.com/kimai/kimai/releases. Kimai ships one most months
and each migrates the database on the way up, so take both backups first, then edit the image
line in /srv/kimai/compose.yml to the new tag and digest:

```bash
cd /srv/kimai
docker compose pull
docker compose up -d
docker compose logs --tail 30 kimai
```

Watch that log until it settles, then re-run step 7's first two checks before calling it done.

## 10. What will probably go wrong

The first `docker compose logs kimai` looks like a catastrophe and is not. The start-up script
has `bash -x` on its first line, so every command it runs is echoed with a `+` in front of it,
interleaved with `Testing DB:` from the wait loop, and `docker compose ps` says `unhealthy` for
a minute or two because the image's health check polls immediately and gives up after three
tries. I read that as a crashed install and started pulling the compose file apart before the
login page came up on its own. Give step 7's loop its full 40 rounds first.

## 11. Out of scope

- Do not configure SMTP or set `MAILER_URL`. Kimai runs with mail off; the cost is
  password-reset and notification email, and the admin creates accounts by hand.
- Do not enable LDAP or SAML. Both need an identity provider this install does not have, and
  both change how the account from step 7 signs in.
- Do not install plugins from the Kimai store. They need a cache rebuild of their own, and a
  broken one takes the application down.
- Do not turn on self-registration in a `local.yaml`. It is off by default and this host is
  public.
