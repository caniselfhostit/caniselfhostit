You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Matomo 5.12.0 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point here. Say why when you ask: that hostname becomes Matomo's
trusted host and goes inside the tracking snippet on every page they measure.

Matomo and its database need 2048 MB of RAM available and 10 GB free on /srv, what upstream
sizes for a site tracking 100,000 page views a month. Both images are amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name nobody can resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/matomo /srv/matomo/backups
sudo install -d -m 750 /srv/matomo/matomo
sudo install -d -m 700 /srv/matomo/mariadb
ls -la /srv/matomo
```

Assert: `backups` owned by the login user, `matomo` at mode `750` and `mariadb` at mode `700`,
both owned by root. Leave those two alone: the Matomo image unpacks its PHP tree into `matomo`
and chowns it to www-data, MariaDB chowns its own data directory, and each refuses a directory
someone claimed first.

## 3. Secrets

Two secrets: the `matomo` database user's password and the MariaDB root password. Matomo ships
no account and no admin token of its own; the wizard in step 7 creates the first user. Print
neither value, keep both out of your summary and out of every log line.

```bash
umask 077
cat > /srv/matomo/.env <<EOF
MARIADB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/matomo/.env
umask 022
ls -l /srv/matomo/.env
```

Assert: mode `-rw-------` and the login user's name twice. Compose reads this file for the
`${...}` substitutions in compose.yml whenever it runs from /srv/matomo and never mounts it
into a container.

## 4. compose.yml

```bash
cat > /srv/matomo/compose.yml <<'EOF'
# Matomo · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image README ....... https://github.com/matomo-org/docker
#   docker install FAQ . https://matomo.org/faq/how-to-install/install-matomo-with-docker/
#   archiving cron ..... https://matomo.org/faq/on-premise/how-to-set-up-auto-archiving-of-your-reports/
#
# Three services. `app` is Apache with PHP; `archive` is the same image with a
# loop around `console core:archive` in place of its entrypoint, sharing the
# web root because the archiver reads the config the wizard writes. Every
# ${...} comes from /srv/matomo/.env, mode 600. Digests read 2026-08-06; both
# images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: matomo-db
    restart: unless-stopped
    # Archiving writes wide rows; upstream's example raises this too.
    command: --max-allowed-packet=64MB
    environment:
      MARIADB_DATABASE: matomo
      MARIADB_USER: matomo
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - /srv/matomo/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other containers.

  app:
    image: matomo:5.12.0-apache@sha256:85d27206a4acdd43259909aa00cab1913dec88cfba53e1ce66a51e6caa430a55
    container_name: matomo-app
    restart: unless-stopped
    environment:
      # These six only prefill the wizard's database form; after that the
      # credentials live in config.ini.php and these are never read again.
      MATOMO_DATABASE_HOST: db
      MATOMO_DATABASE_ADAPTER: mysql
      MATOMO_DATABASE_TABLES_PREFIX: matomo_
      MATOMO_DATABASE_USERNAME: matomo
      MATOMO_DATABASE_PASSWORD: ${MARIADB_PASSWORD}
      MATOMO_DATABASE_DBNAME: matomo
      PHP_MEMORY_LIMIT: 512M
    volumes:
      - /srv/matomo/matomo:/var/www/html
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/index.php || exit 1"]
      interval: 10s
      retries: 24
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8119.
      - "127.0.0.1:8119:80"
    depends_on:
      db:
        condition: service_healthy

  archive:
    image: matomo:5.12.0-apache@sha256:85d27206a4acdd43259909aa00cab1913dec88cfba53e1ce66a51e6caa430a55
    container_name: matomo-archive
    restart: unless-stopped
    # Apache's user, so what this writes stays readable by the web process.
    # Reports are computed here, hourly, never on a page load.
    user: www-data
    environment:
      PHP_MEMORY_LIMIT: 512M
    volumes:
      - /srv/matomo/matomo:/var/www/html
    entrypoint: ["/bin/sh", "-c", "while true; do [ -s /var/www/html/config/config.ini.php ] && php /var/www/html/console core:archive --no-ansi; sleep 3600; done"]
    depends_on:
      app:
        condition: service_started
EOF
cd /srv/matomo && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Upstream documents archiving as a script running hourly, and
without that third container Matomo computes reports while somebody waits on a page load.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy it first: a syntax error takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-matomo
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Matomo · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://matomo.org/faq/how-to-install/faq_98/ and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also Matomo's trusted host and the address inside the tracking snippet on
# every page you measure.

<DOMAIN> {
	encode zstd gzip

	# Matomo sets its own X-Frame-Options and CSP; these are the rest.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# Caddy passes the Host through and adds X-Forwarded-For, which
	# trusted_hosts[] and proxy_client_headers[] read. 8119 is loopback only.
	reverse_proxy 127.0.0.1:8119
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-matomo, reload, and
report the objection. Caddy gets the certificate on first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, and idempotent on a box Prompt Zero configured:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8119 stays closed because compose binds it to loopback, 3306 because compose never
publishes it. Assert: `Status: active`, rules for 80, 443/tcp, 443/udp, nothing else.

## 7. Start and verify

The first start unpacks about 200 MB of PHP into /srv/matomo/matomo, so give it time.

```bash
cd /srv/matomo
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/index.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ | grep -c 'Matomo is libre software used to analyze traffic from your visitors'
```

Assert: the loop ends on `200`, the grep prints `1`, and you print both. If either misses,
stop, run `docker compose logs --tail 40 app` and `docker compose logs --tail 20 db`, and name
the likely step: a database that never reports healthy is step 2, a lasting `502` is step 5. A
running container is not success.

Now write the settings the wizard never asks about, into a file it reads first and cannot
overwrite.

```bash
cd /srv/matomo
docker compose exec -T -u www-data app sh -c 'cat > /var/www/html/config/common.config.ini.php' <<'EOF'
[General]
; Caddy terminates TLS, so Matomo is told the request arrived over https.
assume_secure_protocol = 1
force_ssl = 1
proxy_client_headers[] = HTTP_X_FORWARDED_FOR
; The only hostname allowed in a Host header.
trusted_hosts[] = "<DOMAIN>"
; Reports come from the archive container, not from a page load.
enable_browser_archiving_triggering = 0
browser_archiving_disabled_enforce = 1
EOF
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/index.php
```

Assert: that prints `200`. A `500` is a typo in that file; read it back with
`docker compose exec -T app cat /var/www/html/config/common.config.ini.php` and fix it.

STOP: tell the user to open https://<DOMAIN>, work through the wizard, and wait. Do not
continue until they confirm. Tell them three things: the database screen is filled in and
its password masked, so they keep the adapter on its default and press Next; the superuser
they create is this install's only account and goes in their password manager now; the
website they name last owns the snippet Matomo prints at the end.

Once they confirm, prove the install is real and the wizard is closed:

```bash
cd /srv/matomo
curl -sS 'https://<DOMAIN>/index.php?module=Installation&action=welcome' | grep -c 'Matomo is already installed'
docker compose exec -T -u www-data app php /var/www/html/console config:get --section=General --key=trusted_hosts | grep -c '<DOMAIN>'
curl -sS -o /dev/null -w '%{http_code}\n' 'https://<DOMAIN>/matomo.php?idsite=1&rec=1&action_name=selfhost-check&url=https%3A%2F%2Fexample.com%2F'
sleep 5
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from matomo_log_visit" "$MARIADB_DATABASE"'
docker compose exec -T -u www-data app php /var/www/html/console core:archive --no-ansi | tail -5
```

Assert all five, printing what you received for each. The first grep prints `1`, the security
assert here: the wizard now refuses anyone who finds that URL. The second prints `1`, so the
effective config names that hostname and no other. The tracker returns `200`. The count is `1`
or more, the product working end to end, a tracking request that became a row. It ends with
`Done archiving!`. A `0` count means the tracker took the request and dropped it: stop and read
`docker compose logs --tail 40 app`. A failed archive run means reports stop refreshing.

The first screen at https://<DOMAIN> now shows the heading `Sign in` above a
`Username or e-mail` field, a `Password` field and a `Lost your password?` link.

## 8. First backup and restore

Two artifacts. The database holds every visit, user and computed report. The config archive
holds what rebuilds the service around it, including the `config` directory Matomo wrote its
credentials into.

```bash
cd /srv/matomo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/matomo/backups/matomo-db-$(date +%F).sql.gz
sudo tar -czf /srv/matomo/backups/matomo-config-$(date +%F).tar.gz -C /srv/matomo compose.yml .env matomo/config -C /etc/caddy Caddyfile
ls -lh /srv/matomo/backups/
```

Assert: both files exist, both are non-empty, both sizes printed. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database.

A backup on the same disk as the data is not a backup. Run this one from the user's machine,
not the server:

```bash
mkdir -p ~/backups/matomo
scp vps:/srv/matomo/backups/* ~/backups/matomo/
```

To restore: `docker compose down`, `sudo rm -rf /srv/matomo/mariadb`, recreate it as in step 2,
untar the config archive at /srv/matomo so `.env` and `matomo/config` come back,
`docker compose up -d db`, wait about
30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`. Tell the user why that order matters: MariaDB takes its password
from .env the moment it initialises an empty directory, and Matomo will not start without
`config`, the one part of the web root the image does not ship.

## 9. Updating later

New versions are listed at https://github.com/matomo-org/matomo/releases. Take both backups
first, then edit both image lines in /srv/matomo/compose.yml to the new tag and digest: `app`
and `archive` share an image, and a mismatch runs last month's archiver on this month's schema.

```bash
cd /srv/matomo
docker compose pull
docker compose up -d
docker compose exec -T -u www-data app php /var/www/html/console core:update --no-interaction
docker compose logs --tail 30 app
```

Matomo does not migrate its schema on boot, which is what `core:update` is for. Re-run step 7's
tracker and archive checks before calling the update done.

## 10. What will probably go wrong

The dashboard will be empty on the day it is installed and the user will decide tracking is
broken. Mine was. Step 7 turned off the archiving a page load used to trigger, so nothing is
computed until the archive container's hourly pass. The raw hits are in the database the whole
time. Before touching anything, run
`docker compose exec -T -u www-data app php /var/www/html/console core:archive --no-ansi` and
reload. If the numbers appear, nothing was wrong and the fix is to wait.

## 11. Out of scope

- Do not configure SMTP. Matomo runs without mail, and its scheduled email reports are a
  second install to do properly.

- Do not enable browser-triggered archiving to make today's numbers appear sooner. That is the
  setting step 7 turned off, and turning it back on is how a Matomo gets slow.
- Do not install Marketplace plugins now. Heatmaps, Funnels and the rest are paid licences,
  and each is a schema change on a database with one backup.
- Do not sign up with MaxMind or hand-install a GeoIP database. Matomo downloads a free DB-IP
  city database from its own Geolocation screen, later, if the user wants it.
