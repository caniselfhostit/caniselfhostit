You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Akaunting 3.1.21 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` or `<ADMIN_EMAIL>` is still literal, ask the user for both once and stop until
they answer. `<DOMAIN>` becomes `APP_URL`, the `<base href>` on every page and the address in
every client-portal link a customer gets; its A record must already point here.
`<ADMIN_EMAIL>` is the sign-in name of the one account this creates.

Tell the user this first: Akaunting is source-available rather than open source, and its
licence grants free production use for up to two users, one company and one thousand invoices.
Past any of those, upstream sells an on-premise plan.

Akaunting needs 2048 MB of RAM available and 10 GB free on /srv. Both images have arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/akaunting /srv/akaunting/backups
sudo install -d -m 700 /srv/akaunting/mariadb
ls -la /srv/akaunting
```

Assert: `backups` owned by the login user, `mariadb` at mode `700` owned by root. Leave that
one alone: MariaDB chowns its data directory on first start and refuses one somebody claimed
first. The application gets no directory here; step 4 keeps it in a named volume.

## 3. Secrets

Three secrets, all generated here: the MariaDB password for the `akaunting` database user, the
MariaDB root password, and the password the installer puts on the first account. Print none of
them, keep them out of your summary, and keep them out of every log line.

```bash
umask 077
cat > /srv/akaunting/.env <<EOF
APP_URL=https://<DOMAIN>
LOCALE=en-US
COMPANY_NAME=My Company
COMPANY_EMAIL=<ADMIN_EMAIL>
ADMIN_EMAIL=<ADMIN_EMAIL>
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
AKAUNTING_SETUP=true
EOF
chmod 600 /srv/akaunting/.env
umask 022
ls -l /srv/akaunting/.env
```

Assert: mode `-rw-------` and the login user's name twice. Compose reads it for the `${...}`
substitutions in compose.yml whenever it runs from /srv/akaunting, so it is never mounted into
a container. `AKAUNTING_SETUP` runs the installer once, and step 7 takes it away.

## 4. compose.yml

```bash
cat > /srv/akaunting/compose.yml <<'EOF'
# Akaunting · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image README ... https://github.com/akaunting/docker/blob/master/README.md
#   entrypoint ..... https://github.com/akaunting/docker/blob/master/files/akaunting.sh
#   variables ...... https://github.com/akaunting/docker/blob/master/env/run.env.example
#
# Akaunting's Apache image and the MariaDB holding the books. /var/www/html is
# a named volume because the image ships the application there and chowns it;
# MariaDB chowns its own directory, so that one is the bind mount. 3.1.21 is the
# newest tag akaunting/docker has published, and 3.2.1 has no image behind it.
# Digests read 2026-08-06, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: akaunting-db
    restart: unless-stopped
    # Upstream's install page asks for utf8mb4_general_ci.
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
    environment:
      MARIADB_DATABASE: akaunting
      MARIADB_USER: akaunting
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - /srv/akaunting/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  akaunting:
    image: akaunting/akaunting:3.1.21@sha256:50940112be48a229a2f567dc50ace9886fe5b14e1fe33f0232e704d0fb96f29f
    container_name: akaunting
    restart: unless-stopped
    environment:
      # The <base href> on every page: the scheme and host Caddy answers on.
      APP_URL: ${APP_URL}
      LOCALE: ${LOCALE}
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: akaunting
      DB_USERNAME: akaunting
      DB_PASSWORD: ${DB_PASSWORD}
      DB_PREFIX: ""
      COMPANY_NAME: ${COMPANY_NAME}
      COMPANY_EMAIL: ${COMPANY_EMAIL}
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      # The installer runs while AKAUNTING_SETUP is set; step 7 deletes it.
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:-}
      AKAUNTING_SETUP: ${AKAUNTING_SETUP:-}
    volumes:
      - akaunting-html:/var/www/html
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8151.
      - "127.0.0.1:8151:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  akaunting-html:
EOF
cd /srv/akaunting && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. No default credential survives it: upstream's example
environment carries a published database password and `me@company.com` on the first account,
and step 3 replaced both. PHP's own defaults ride along, so an attachment over 2 MB is refused.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-akaunting
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Akaunting · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://github.com/akaunting/docker/blob/master/env/run.env.example and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, the <base href> on every page, so the two stay equal.

<DOMAIN> {
	# The interface is HTML and JSON; PDFs are already compressed.
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}
	# No Content-Security-Policy: invoice templates are editable here, and
	# one written blind breaks a printed invoice rather than an attack.

	# 8151 is the loopback port compose publishes here, not a container
	# port, and not open in the firewall.
	reverse_proxy 127.0.0.1:8151
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-akaunting, reload,
and report the objection. Caddy gets the certificate on the first request, then renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8151 is bound to 127.0.0.1 and 3306 is never published, so neither has a host port
to firewall. Assert: `Status: active`, rules for 80, 443/tcp, 443/udp, nothing else.

## 7. Start and verify

MariaDB initialises, then the entrypoint runs `php artisan install`: it writes the
application's own .env inside the volume with a fresh `APP_KEY`, builds the schema, and creates
the company and the account. Apache starts when that finishes, a minute or two later.

```bash
cd /srv/akaunting
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/auth/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/auth/login | grep -o 'Login to start your session'
docker compose logs akaunting | grep -c 'Creating admin'
```

Assert all three, printing what you got: the loop ends on `200`; then
`Login to start your session`; then `1`, the installer's own line for the account it made. On
any miss, stop, run `docker compose logs --tail 60 akaunting` and
`docker compose logs --tail 20 db`, and name the step: `Unable to find database!` is step 3's
password never reaching the database, `Missing options are` is an empty value in .env, a
lasting `502` is step 5. A running container is not success.

The first screen at https://<DOMAIN>/ redirects to https://<DOMAIN>/auth/login, which shows the
Akaunting logo over the line `Login to start your session`, an `Email` box, a `Password` box
and a `Login` button.

STOP: tell the user to read the password with `grep ADMIN_PASSWORD /srv/akaunting/.env`, put it
in their password manager, sign in at https://<DOMAIN>/auth/login with `<ADMIN_EMAIL>`, rename
the company under Settings, confirm the dashboard loads, and wait.
Do not continue until they confirm. The next block deletes this server's copy of that password.

Close the bootstrap out:

```bash
cd /srv/akaunting
sed -i -e '/^ADMIN_PASSWORD/d' -e '/^AKAUNTING_SETUP/d' /srv/akaunting/.env
docker compose up -d --force-recreate akaunting
sleep 45
docker compose logs akaunting | grep -c 'Creating admin' || true
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/auth/login
```

Assert both: the count that read `1` now prints `0`, and the status prints `200`. That `0` is
the security assert here, because the replaced container starts Apache without running the
installer again: no second company, no second account, no bootstrap password on disk. There is
no reset mail here, so that password manager entry is the recovery plan.

## 8. First backup and restore

Three artifacts: the dump holds customers, vendors, invoices, bills and transactions; the
application archive holds the volume's .env, whose `APP_KEY` decrypts what Laravel encrypted,
plus attachments; the config archive rebuilds the service around both.

```bash
cd /srv/akaunting
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --no-tablespaces -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/akaunting/backups/akaunting-db-$(date +%F).sql.gz
docker compose exec -T akaunting tar -C /var/www/html -czf - .env storage modules > /srv/akaunting/backups/akaunting-app-$(date +%F).tar.gz
sudo tar -czf /srv/akaunting/backups/akaunting-config-$(date +%F).tar.gz -C /srv/akaunting compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/akaunting/backups/
```

Assert: all three exist, all three are non-empty, and print all three sizes. Nothing goes
offline: `--single-transaction` snapshots a running InnoDB database, and `--no-tablespaces` is
there because the `akaunting` user is not a superuser. The password is read inside the database
container, so it never reaches the host process list.

A backup on the same disk is not a backup. Run this from the user's machine, not the server:

```bash
mkdir -p ~/backups/akaunting
scp vps:/srv/akaunting/backups/* ~/backups/akaunting/
```

To restore: `docker compose down -v`, the one place `-v` belongs, because it drops the
application volume on purpose. `sudo rm -rf /srv/akaunting/mariadb` and recreate it as in step
2. Untar the config archive into /srv/akaunting so .env is back first, since MariaDB reads its
passwords from it as it initialises. `docker compose up -d db`, wait 30 seconds for healthy,
pipe `gunzip -c` on the dump into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Then `docker compose up -d akaunting`, which refills the volume from the image,
`docker compose exec -T akaunting tar -C /var/www/html -xzf - < backups/akaunting-app-<date>.tar.gz`,
and `docker compose restart akaunting` to put the ownership back. What is at stake at 2am: this
database is what they file taxes from.

## 9. Updating later

Two things move separately. A newer image tag moves PHP, Apache and the image's own copy of
the application, but the copy that runs lives in the `akaunting-html` volume, which Docker
filled once and will not fill again, so these three move the runtime and nothing else:

```bash
cd /srv/akaunting
docker compose pull
docker compose up -d
docker compose logs --tail 30 akaunting
```

Image tags are at https://hub.docker.com/r/akaunting/akaunting/tags and releases at
https://github.com/akaunting/akaunting/releases. Take all three backups first, then edit the
image line in compose.yml to the new tag and digest. Akaunting itself moves with the updater
upstream documents: `docker compose exec -T akaunting php artisan update:all`.

## 10. What will probably go wrong

The first two minutes look like a failed install. `docker compose ps` says the application
container is `Up`, curl returns nothing at all, and the log sits on
`Connecting to database akaunting@db:3306` while the entrypoint retries every five seconds. I
went hunting for the bug and there was not one: the entrypoint runs the whole installer before
Apache starts, so there is no half-built page to look at while it works. Give step 7's loop its
full 40 rounds. When it fails for real it fails loudly, with `Unable to find database!` after
30 seconds of retries, and that points at step 3.

## 11. Out of scope

- Do not configure SMTP. Akaunting runs without it, and the cost is that Email Invoice does
  nothing, so the user sends the PDF or the portal link themselves.
- Do not add a cron container or a scheduler service. Nothing here runs Laravel's scheduler, so
  recurring invoices and reminder mail never fire.
- Do not enter an Akaunting API key or install anything from the app store. Those apps are
  purchases tied to an akaunting.com account, and the double-entry ledger is one of them.
- Do not create a second company or extra user accounts. The licence grants production use for
  one company and two users.
