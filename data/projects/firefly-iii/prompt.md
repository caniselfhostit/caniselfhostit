You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Firefly III 6.6.6 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
It becomes `APP_URL`, which Firefly III builds every link and form action from, and its A
record has to point at this server already.

Firefly III with its database needs 2048 MB of RAM available and 10 GB free on /srv. All three
images publish amd64 and arm64. Measure all four:

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop.

Say this to the user before step 2, because it is the expectation this install does not meet:
Firefly III has no bank connection. Transactions arrive as CSV files exported from the bank, or
through the Firefly III Data Importer, a second application on its own hostname, out of scope
here.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/firefly-iii /srv/firefly-iii/backups
sudo install -d -m 700 /srv/firefly-iii/mariadb
sudo install -d -m 750 -o 33 -g 33 /srv/firefly-iii/upload
ls -la /srv/firefly-iii
```

Assert: `backups` owned by the login user, `mariadb` at mode `700` owned by root, `upload`
owned by uid `33`. Leave `mariadb` alone: the MariaDB image chowns its own data directory on
first start. `upload` is the opposite case. The application image runs as `www-data`, uid 33,
and never chowns a mount, so a directory owned by anyone else means attachments fail to save
while nothing else looks wrong.

## 3. Secrets

Three secrets: the Laravel application key, the database password, and the token the cron
container calls the application with. Do not print any of them, do not repeat them in your
summary, do not put them in a log line. Hex, because upstream documents both `APP_KEY` and
`STATIC_CRON_TOKEN` as exactly 32 characters with special characters avoided, and
`openssl rand -hex 16` is 32 characters of `0-9a-f`.

```bash
umask 077
cat > /srv/firefly-iii/.env <<EOF
APP_URL=https://<DOMAIN>
TZ=UTC
TRUSTED_PROXIES=**
APP_KEY=$(openssl rand -hex 16)
DB_PASSWORD=$(openssl rand -hex 32)
STATIC_CRON_TOKEN=$(openssl rand -hex 16)
EOF
chmod 600 /srv/firefly-iii/.env
umask 022
ls -l /srv/firefly-iii/.env
awk -F= '/^APP_KEY=/{print "APP_KEY length: " length($2)}' /srv/firefly-iii/.env
```

Assert: mode `-rw-------`, and the length line prints `APP_KEY length: 32`. Anything else and
Firefly III refuses to boot. `TRUSTED_PROXIES=**` is upstream's documented value behind a
reverse proxy. Tell the user `APP_KEY` is the value they cannot lose: upstream's backup page
names it first, and a database restored without it is a ledger nobody can read.

## 4. compose.yml

```bash
cat > /srv/firefly-iii/compose.yml <<'EOF'
# Firefly III · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   docker install ..... https://docs.firefly-iii.org/how-to/firefly-iii/installation/docker/
#   variable reference . https://github.com/firefly-iii/firefly-iii/blob/v6.6.6/.env.example
#   cron jobs .......... https://docs.firefly-iii.org/how-to/firefly-iii/advanced/cron/
#
# Three services. `app` is nginx and PHP-FPM in one image, running as www-data,
# uid 33, which never chowns a mount, so step 2 hands it /srv/firefly-iii/upload
# already owned by 33. `db` is the MariaDB upstream's compose file uses, pinned
# to a version instead of the moving `lts` tag. `cron` is BusyBox crond calling
# the application's own cron endpoint daily, because upstream states the image
# runs no scheduler; upstream's cron container installs tzdata at every start,
# dropped here in favour of one fixed timezone. Every ${...} comes from
# /srv/firefly-iii/.env, mode 600. Digests read 2026-08-07, all three multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: firefly
      MARIADB_USER: firefly
      MARIADB_PASSWORD: ${DB_PASSWORD}
      # Upstream's database.env has the image invent a root password rather
      # than store one. It lands in this container's log once and is never used.
      MARIADB_RANDOM_ROOT_PASSWORD: "true"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/firefly-iii/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other containers.

  app:
    image: fireflyiii/core:version-6.6.6@sha256:ae69fdd95cdef9038cd7a460a5aec731f14813973e4f096511d5a4ea9ff0e972
    restart: unless-stopped
    env_file: /srv/firefly-iii/.env
    environment:
      APP_ENV: production
      DB_CONNECTION: mysql
      DB_HOST: db
      DB_PORT: "3306"
      DB_DATABASE: firefly
      DB_USERNAME: firefly
      # Laravel's log mailer, upstream's own default: nothing waits on SMTP.
      MAIL_MAILER: log
      # The image's health check curls the path this names. Its default,
      # /healthcheck, is not a route here; /health answers with `OK`.
      HEALTHCHECK_PATH: /health
    volumes:
      - /srv/firefly-iii/upload:/var/www/html/storage/upload
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8155.
      - "127.0.0.1:8155:8080"
    depends_on:
      db:
        condition: service_healthy

  cron:
    image: alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b
    restart: unless-stopped
    env_file: /srv/firefly-iii/.env
    # 03:00 daily: recurring transactions, auto-budgets, rates, bill warnings.
    # The doubled $$ is compose's escape for one $, so the token is read inside
    # the container and never appears here. TZ is UTC, so BusyBox needs no tzdata.
    command: ["sh", "-c", "echo '0 3 * * * wget -qO- http://app:8080/api/v1/cron/'$$STATIC_CRON_TOKEN | crontab - && crond -f -L /dev/stdout"]
    depends_on:
      app:
        condition: service_started
EOF
cd /srv/firefly-iii && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, one published port, no database port.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-firefly-iii
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Firefly III · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.firefly-iii.org/how-to/firefly-iii/installation/docker/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also APP_URL in .env, and if the two disagree the forms post to an address
# that does not answer.

<DOMAIN> {
	# Statements and attachments travel both ways, so compression earns a place.
	encode zstd gzip

	header {
		# A ledger of every account you own is worth a downgrade attack.
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "same-origin"
		-Server
	}

	# 8155 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8155
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-firefly-iii, reload, and report what it objected to. Caddy gets the
certificate on the first request and renews it. Nothing to schedule.

## 6. Firewall

Two ports open, both Caddy's. Idempotent: on a Prompt Zero box they change nothing.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the way in, 443/udp is
HTTP/3. 8155 is bound to 127.0.0.1 and 3306 is never published, so neither belongs here.
Assert: `Status: active`, rules for 80, 443/tcp and 443/udp, nothing for 8155 or 3306.

## 7. Start and verify

Firefly III builds its schema on the way up, and on an empty database that takes a minute or
two, during which the site answers 500. The loop waits it out.

```bash
cd /srv/firefly-iii
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/health
curl -sS https://<DOMAIN>/login | grep -c 'Sign in to start your session'
docker compose exec -T cron sh -c 'wget -qO- http://app:8080/api/v1/cron/$STATIC_CRON_TOKEN'
```

Assert all four, printing what you got for each. The loop ends on `200`. Health answers
with the two letters `OK`. The grep prints `1`, meaning the first screen at
https://<DOMAIN>/login carries the heading `Sign in to start your session`. The last command
prints JSON containing `"recurring_transactions"` and `"job_fired":true`, proving the cron
container reaches the application and its token is accepted. If any of the four misses, stop,
run `docker compose logs --tail 40 app` and `docker compose logs --tail 20 db`, and name the
likely cause: a database that never reports healthy points at step 2; a `500` that never clears
points at an `APP_KEY` that is not 32 characters; a `404` in place of health means Caddy is not
reaching the container. A running container is not success.

STOP: tell the user to open https://<DOMAIN>/register, create the first account with an email
address and a password they put in their password manager, and wait.
Do not continue until they confirm. This install sends no mail, so there is no password reset
and that password is the only way back in.

Once they confirm, prove registration closed behind them.

```bash
curl -sS https://<DOMAIN>/register | grep -c 'Registration is currently not available'
```

Assert: that prints `1`. Firefly III ships in single-user mode, so the register page serves a
form while the database holds no users and refuses everyone after the first.

## 8. First backup and restore

Three artifacts, taken before the user enters a transaction. The dump holds accounts,
transactions, budgets and rules; the upload archive holds attachments; the config archive holds
the files that rebuild the service around them, `.env` among them, where `APP_KEY` lives.

```bash
cd /srv/firefly-iii
docker compose exec -T db sh -c 'exec mariadb-dump -ufirefly -p"$MARIADB_PASSWORD" --single-transaction firefly' | gzip > /srv/firefly-iii/backups/firefly-iii-db-$(date +%F).sql.gz
sudo tar -czf /srv/firefly-iii/backups/firefly-iii-upload-$(date +%F).tar.gz -C /srv/firefly-iii upload
sudo tar -czf /srv/firefly-iii/backups/firefly-iii-config-$(date +%F).tar.gz -C /srv/firefly-iii compose.yml .env -C /etc/caddy Caddyfile
ls -lh /srv/firefly-iii/backups/
```

Assert: all three exist, none is empty, print all three sizes. Nothing is stopped:
`--single-transaction` snapshots a running InnoDB database consistently, and the password is
read inside the container from its own environment, so it never reaches this terminal.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/firefly-iii
scp vps:/srv/firefly-iii/backups/* ~/backups/firefly-iii/
```

To restore, in this order: `docker compose down`, then untar the config archive into
/srv/firefly-iii so `.env` is back before any container starts, because MariaDB reads its
password from that file the moment it initialises an empty data directory. Then
`sudo rm -rf /srv/firefly-iii/mariadb`, recreate it as in step 2, `docker compose up -d db`,
wait about 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -ufirefly -p"$MARIADB_PASSWORD" firefly'`, untar
the upload archive back, then `docker compose up -d`. Tell the user a dump without `.env` is
not a restore.

## 9. Updating later

New versions are listed at https://github.com/firefly-iii/firefly-iii/releases; the image tag
for a release is `version-` plus its number. Take all three backup artifacts first, then edit
the image line in /srv/firefly-iii/compose.yml to the new tag and digest:

```bash
cd /srv/firefly-iii
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

Firefly III migrates its own database on the way up, so watch that log until it settles, then
re-run the health check from step 7 before calling the update done.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a failed install for about two minutes. I opened
https://<DOMAIN> the second the command returned, got a blank Laravel error page, reloaded
twice, and started reading the compose file for a typo that was not there. Firefly III was
building its schema: dozens of migrations run on the first boot, and until the last one lands
every request answers 500. The loop in step 7 exists so nobody guesses. If it still fails
after forty attempts, check the `APP_KEY` length line from step 3.

## 11. Out of scope

- Do not install the Firefly III Data Importer. It is a separate application with its own
  container, hostname and access token; this prompt installs the ledger it would feed.
- Do not configure SMTP. `MAIL_MAILER` is `log` here, upstream's own default.
- Do not set `FIREFLY_III_LAYOUT=v2`. Upstream calls that layout very experimental and warns
  about data loss in the same breath.
- Do not regenerate `APP_KEY` or run `php artisan key:generate` here. The key that encrypted
  the data is the only key that reads it back.
