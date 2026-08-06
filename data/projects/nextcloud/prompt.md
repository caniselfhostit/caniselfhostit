You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Nextcloud 34.0.2 on that server, reachable at https://<DOMAIN>, behind the existing
Caddy with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname once and stop until they answer.
Its A record must already point at this server, and Nextcloud reads its trusted-domain list
only at first install, so changing the hostname later is an occ command.

Nextcloud with its database needs 2048 MB of RAM available and 10 GB free on /srv. Upstream
asks 512 MB per PHP process alone; the rest is MariaDB, Redis and restart headroom. All three
images publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot get a
certificate for a name that does not resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/nextcloud /srv/nextcloud/backups
sudo install -d -m 750 /srv/nextcloud/html
sudo install -d -m 700 /srv/nextcloud/mariadb
ls -la /srv/nextcloud
```

Assert: `backups` owned by the login user, `html` at mode `750` and `mariadb` at mode `700`,
both owned by root. Leave those two alone: the Nextcloud image copies 600 MB of PHP into `html`
and chowns it to www-data, MariaDB chowns its own data directory, and both refuse a directory
you claimed first.

## 3. Secrets

Three secrets: the `nextcloud` database password, the MariaDB root password, and the first
administrator's password. Generate all three on the server. Do not print any of them, do not
repeat them in your summary, do not put them in a log line.

```bash
umask 077
cat > /srv/nextcloud/.env <<EOF
NEXTCLOUD_TRUSTED_DOMAINS=<DOMAIN>
OVERWRITECLIURL=https://<DOMAIN>
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -hex 24)
MYSQL_PASSWORD=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 /srv/nextcloud/.env
umask 022
ls -l /srv/nextcloud/.env
```

Assert: mode `-rw-------`. The administrator is named `admin` because a Nextcloud account
cannot be renamed later; step 7 gives the command that reads the password back.

## 4. compose.yml

```bash
cat > /srv/nextcloud/compose.yml <<'EOF'
# Nextcloud · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image README ..... https://github.com/nextcloud/docker
#   requirements ..... https://docs.nextcloud.com/server/34/admin_manual/installation/system_requirements.html
#   reverse proxy .... https://docs.nextcloud.com/server/34/admin_manual/configuration_server/reverse_proxy_configuration.html
#
# Four services. `app` is Apache with PHP; `cron` is the same image with its
# entrypoint replaced by the /cron.sh it ships, sharing a volume because the
# jobs must see the tree the web process writes. MariaDB 11.8 is what the
# Nextcloud 34 requirements page recommends; Redis holds the file lock. Every
# ${...} comes from /srv/nextcloud/.env, mode 600. Digests read 2026-08-05.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED
    environment:
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: ${MYSQL_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - /srv/nextcloud/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: nextcloud-redis
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` and no volume: locks and cache, on a private network.

  app:
    image: nextcloud:34.0.2-apache@sha256:d7666d54d87c58d52869ddda36d1acbd4a7f53faf8ab6b91293daf204f3434e8
    container_name: nextcloud-app
    restart: unless-stopped
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      # Present before the first launch, these three make the entrypoint
      # install Nextcloud itself, so no setup wizard ever sits open.
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_TRUSTED_DOMAINS}
      # Caddy terminates TLS and speaks plain http here. Without these,
      # every link Nextcloud builds points at http and login loops.
      OVERWRITEPROTOCOL: https
      OVERWRITECLIURL: ${OVERWRITECLIURL}
      # The only client address this container sees is Docker's bridge
      # gateway. Trust it and the visitor arrives in X-Forwarded-For.
      TRUSTED_PROXIES: 172.16.0.0/12
    volumes:
      # NOTE: the `volumes` of `app` and `cron` have to match.
      - /srv/nextcloud/html:/var/www/html
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8099.
      - "127.0.0.1:8099:80"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  cron:
    image: nextcloud:34.0.2-apache@sha256:d7666d54d87c58d52869ddda36d1acbd4a7f53faf8ab6b91293daf204f3434e8
    container_name: nextcloud-cron
    restart: unless-stopped
    # /cron.sh and a crontab running cron.php every five minutes ship in
    # the image; the entrypoint swap makes this copy the scheduler.
    entrypoint: /cron.sh
    environment:
      # cron.php reads the same runtime config the web process reads: let
      # these drift and jobs take another lock and build dead links.
      REDIS_HOST: redis
      OVERWRITEPROTOCOL: https
      OVERWRITECLIURL: ${OVERWRITECLIURL}
    volumes:
      - /srv/nextcloud/html:/var/www/html
    depends_on:
      app:
        condition: service_started
EOF
cd /srv/nextcloud && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Four services, one published port. Two run the same image,
one serving the site and one running the scheduler.

## 5. Caddy and TLS

Append the block below to the Caddyfile Prompt Zero installed, with `<DOMAIN>` replaced by the
real hostname. Copy the file first: a syntax error here takes down every site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-nextcloud
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Nextcloud · the Caddy site block for this service.
#
# Authored by caniselfhostit from
# https://docs.nextcloud.com/server/34/admin_manual/configuration_server/reverse_proxy_configuration.html
# and https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile, the Caddy that Prompt Zero installed,
# with <DOMAIN> replaced by the hostname pointed at this box. That hostname is
# also NEXTCLOUD_TRUSTED_DOMAINS in .env, which Nextcloud reads once, at first
# install. Changing it later is an occ command, not an edit here.

<DOMAIN> {
	# Nextcloud sets its own X-Content-Type-Options, X-Frame-Options and
	# Referrer-Policy on every response. The one header it cannot set for
	# itself is HSTS, because it does not terminate the TLS, and its own
	# security check asks for it by name. That is the whole list. No
	# `encode`: what moves through here is compressed already.
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		-Server
	}

	# 8099 is the loopback port compose publishes on this host. It is not a
	# container port and it is not open in the firewall.
	reverse_proxy 127.0.0.1:8099
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Assert: `caddy validate` exits 0 and the reload exits 0. If validate fails, restore
/etc/caddy/Caddyfile.before-nextcloud, reload, and report the objection. Caddy gets the
certificate on the first request and renews it itself, and speaks plain http to the container,
which is why `OVERWRITEPROTOCOL` is `https`.

## 6. Firewall

Two ports open, both Caddy's. Idempotent: on a box Prompt Zero configured they change
nothing.

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8099 is bound to 127.0.0.1 and compose publishes neither 3306 nor 6379, so none of
the three has a host port to firewall. Assert: `Status: active`, 80, 443/tcp, 443/udp, and
nothing else.

## 7. Start and verify

The first start is slow: the entrypoint unpacks Nextcloud into /srv/nextcloud/html, waits for
MariaDB, then installs, because step 3 wrote an admin user and password first.

```bash
cd /srv/nextcloud
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/status.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/status.php
curl -sSL -o /tmp/nc-first-screen.html -w '%{http_code} %{url_effective}\n' https://<DOMAIN>/
grep -c 'id="body-login"' /tmp/nc-first-screen.html
docker compose exec -u www-data -T app php /var/www/html/occ config:system:get memcache.locking
docker compose exec -u www-data -T app php -f /var/www/html/cron.php && echo "cron OK"
```

Assert all five, printing what you received for each. The loop ends on `200`; the status
response contains `"installed":true`, `"maintenance":false` and `"versionstring":"34.0.2"`; the
third line prints `200` and a URL ending in `/login` and the grep prints `1`, which together
say the setup wizard is gone; the occ call prints `\OC\Memcache\Redis`, proof the fourth
container carries the file locks; the last prints `cron OK`. If any misses, stop, run
`docker compose logs --tail 40 app` and `docker compose logs --tail 20 db`, and name the cause:
a database that never reports healthy is step 2, a `502` that never clears is step 5, `Access
through untrusted domain` is .env and the browser disagreeing about the hostname. A running
container is not success.

The first screen at https://<DOMAIN> shows the heading `Log in to Nextcloud` above an
`Account name or email` field and a `Password` field.

STOP: tell the user to read their administrator password with
`sudo grep NEXTCLOUD_ADMIN_PASSWORD /srv/nextcloud/.env`, put it in their password manager,
then sign in at https://<DOMAIN> as `admin` and confirm the files view loads. Wait. Do not
continue until they confirm.

## 8. First backup and restore

Three artifacts: the database holds accounts, shares and the file index, the files archive
holds user data and the install config, the config archive the rest.

```bash
cd /srv/nextcloud
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --on
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/nextcloud/backups/nextcloud-db-$(date +%F).sql.gz
sudo tar -C /srv/nextcloud/html -czf /srv/nextcloud/backups/nextcloud-files-$(date +%F).tar.gz config data
sudo tar -czf /srv/nextcloud/backups/nextcloud-config-$(date +%F).tar.gz -C /srv/nextcloud compose.yml .env -C /etc/caddy Caddyfile
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --off
ls -lh /srv/nextcloud/backups/
```

Assert: three files, none empty, all three sizes printed. The site serves a maintenance page
for the length of the copy, about a minute on a fresh install. Database and files have to come
from one moment, or a restore hands users an index naming files that are not there.

A backup on the same disk as the data is not a backup. Run this from the user's machine:

```bash
mkdir -p ~/backups/nextcloud
scp vps:/srv/nextcloud/backups/* ~/backups/nextcloud/
```

To restore: `docker compose down`, `sudo rm -rf /srv/nextcloud/mariadb /srv/nextcloud/html`,
recreate both as in step 2, untar the config archive into /srv/nextcloud so .env is back before
anything starts, `docker compose up -d db`, wait for healthy, pipe `gunzip -c` on the `.sql.gz`
into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
untar the files archive into /srv/nextcloud/html, `docker compose up -d`. The stakes, in one
line for the user: only that database knows which file belongs to whom.

## 9. Updating later

Releases are listed at https://github.com/nextcloud/server/releases. Take all three backups
first, then edit both `image:` lines in /srv/nextcloud/compose.yml to the new tag and digest:
they are one image and move together.

```bash
cd /srv/nextcloud
docker compose pull
docker compose up -d
docker compose logs --tail 30 app
```

Nextcloud upgrades one major version at a time and refuses to start if asked to skip one, so 34
to 36 is two passes. Watch the log until it settles, then re-run step 7's check.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a failed install for several minutes: Caddy answers
`502` throughout, because the container is still unpacking 600 MB of PHP into
/srv/nextcloud/html and then waiting on MariaDB. I spent that stretch certain the trusted-domain
setting was wrong. It was not. Past ten minutes of `502`, suspect the hostname: the symptom is
`Access through untrusted domain` on the page, `NEXTCLOUD_TRUSTED_DOMAINS` is read only at
first install so editing .env later does nothing. The fix: `docker compose exec -u www-data -T
app php /var/www/html/occ config:system:set trusted_domains 1 --value=<DOMAIN>`.

## 11. Out of scope

- Do not configure SMTP. On a personal install all it buys is password-reset mail, and the
  user knows their own password.
- Do not install Collabora Online or ONLYOFFICE. Each is a second service with its own
  container and memory floor.
- Do not use the updater in the web interface. The image is the update path, and that updater
  rewrites the directory the image owns.
- Do not enable the preview, antivirus or full-text-search apps. Each turns a quiet box into
  a busy one.
