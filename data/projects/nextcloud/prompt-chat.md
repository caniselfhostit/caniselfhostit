This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Nextcloud 34.0.2 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. Nextcloud reads its trusted-domain list once, during the first
install, and nothing you put in `.env` afterwards changes it. Pick the hostname you intend to
keep, because changing it later is an `occ` command run inside the container rather than an
edit to a file.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. If RAM is short, this
is the number to take seriously rather than work around: upstream asks 512 MB for a single PHP
process, and here that process shares a box with MariaDB, Redis and a second copy of the same
image running the scheduler. A 1 GB VPS will install and then fall over during your first real
upload.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/nextcloud /srv/nextcloud/backups
sudo install -d -m 750 /srv/nextcloud/html
sudo install -d -m 700 /srv/nextcloud/mariadb
ls -la /srv/nextcloud
```

You should see: `backups` owned by you, `html` at mode `drwxr-x---` owned by root, and
`mariadb` at mode `drwx------` owned by root.

If you do not: leave the last two owned by root on purpose. The Nextcloud image copies about
600 MB of PHP into `html` on first start and chowns it to www-data itself, and the MariaDB
image chowns its own data directory. A directory you have already chowned to yourself is one
either of them can refuse.

## 3. Secrets

Three secrets: the password for the `nextcloud` database user, the MariaDB root password, and
the password of the first administrator account. All three are generated here, on the server,
and all three go straight into a file only you can read.

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

You should see: mode `-rw-------`, your own username twice, and the path. Replace `<DOMAIN>` on
the first two lines with your real hostname before you paste.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/nextcloud/.env` and
carry on. If the file already existed from an earlier attempt, this block has now overwritten
all three secrets, which is fine before the database exists and a problem afterwards: MariaDB
keeps the password it was created with, so a changed `MYSQL_PASSWORD` against an existing
`/srv/nextcloud/mariadb` produces an access-denied line in the Nextcloud log rather than
anything that mentions passwords.

Do not paste that file, any of the three secrets, or any command output containing them into
this chat window. The account name is `admin` and it cannot be changed later, so the only thing
you need to keep is the password, and step 7 tells you how to read it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/nextcloud/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/nextcloud/compose.yml` and paste again in one go. A warning that
`MYSQL_PASSWORD` is not set means you are not in /srv/nextcloud, which is where the `.env`
compose reads has to be.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-nextcloud /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates the TLS and speaks plain http to the container, which is why
`OVERWRITEPROTOCOL` is `https` in the compose file: without it Nextcloud builds `http://` links
and redirects for a service that is only reachable over https, and the login page bounces you
in a loop that looks like a wrong password.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8099`, `3306` or `6379`.

If you do not: delete anything for those three with `sudo ufw delete allow 8099`. 8099 is bound
to 127.0.0.1 by the compose file, and 3306 and 6379 are never published at all, so neither the
database nor the cache has a host port a firewall rule could apply to. 80/tcp is there to
answer the ACME challenge and redirect to HTTPS, 443/tcp is the only way in, and 443/udp is
HTTP/3, which Caddy offers by default. `Status: inactive` is a different problem: Prompt Zero
left this firewall enabled, so something has turned it off since, and `sudo ufw enable` puts it
back before you go any further.

## 7. Start and verify

The first start is slow. The entrypoint unpacks its copy of Nextcloud into /srv/nextcloud/html,
waits for MariaDB, and then runs the install itself, because step 3 wrote an admin user and
password before the first launch. Expect several minutes of `502` while that happens.

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

You should see, in order: the loop climbing through `502` and ending on `200`; a JSON object
containing `"installed":true`, `"maintenance":false` and `"versionstring":"34.0.2"`; then `200`
and a URL ending in `/login`; then `1`; then `\OC\Memcache\Redis`; then `cron OK`.

If you do not: the `1` from the grep is the one worth understanding. It says the page a visitor
lands on is the login page rather than the setup wizard, which means nobody can walk up to your
hostname and claim the administrator account. A `0` there with `"installed":false` in the
status output means the install did not run, and the cause is almost always a typo in `.env`
that left one of the database variables empty. If the loop never leaves `502`, run
`docker compose logs --tail 40 app`: `Initializing nextcloud` means it is still unpacking and
you should wait, and repeated `Retrying install` means MariaDB has not come up, so read
`docker compose logs --tail 20 db` next. If the page body says `Access through untrusted
domain`, the hostname in `.env` is not the one you typed in the browser.

The first screen at https://<DOMAIN> shows the heading `Log in to Nextcloud` above an
`Account name or email` field and a `Password` field.

Read your password once, on the server, and put it straight into your password manager:

```bash
sudo grep NEXTCLOUD_ADMIN_PASSWORD /srv/nextcloud/.env
```

Then sign in at https://<DOMAIN> as `admin` and confirm the files view loads. Do not paste that
password, or the line that command printed, into this chat window. A running container is not
success; the login is.

## 8. First backup and restore

Three artifacts. The database holds the accounts, the shares and the file index. The files
archive holds your data and the configuration Nextcloud wrote during install. The config
archive holds what rebuilds the service around them.

```bash
cd /srv/nextcloud
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --on
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/nextcloud/backups/nextcloud-db-$(date +%F).sql.gz
sudo tar -C /srv/nextcloud/html -czf /srv/nextcloud/backups/nextcloud-files-$(date +%F).tar.gz config data
sudo tar -czf /srv/nextcloud/backups/nextcloud-config-$(date +%F).tar.gz -C /srv/nextcloud compose.yml .env -C /etc/caddy Caddyfile
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --off
ls -lh /srv/nextcloud/backups/
```

You should see: `Maintenance mode enabled`, then three files listed, the database dump a few
tens of kilobytes on a fresh install and the files archive a few megabytes, then
`Maintenance mode disabled`. The site serves a maintenance page for the minute this takes.

If you do not: a warning from `mariadb-dump` about a password on the command line is expected
and harmless, because the password came from the container's own environment and never touched
your shell. A `.sql.gz` of about 20 bytes is an empty dump, which means the command failed and
the shell created the file anyway; run the dump line without `| gzip` to read the error. If
maintenance mode is still on when you finish, run the `--off` line again, because Nextcloud
will not serve anything until you do.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/nextcloud
scp vps:/srv/nextcloud/backups/* ~/backups/nextcloud/
```

You should see: three files copied, and all three listed by `ls -lh ~/backups/nextcloud/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the `vps` alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty account:

```bash
cd /srv/nextcloud
docker compose down
sudo rm -rf /srv/nextcloud/mariadb
sudo install -d -m 700 /srv/nextcloud/mariadb
docker compose up -d db
sleep 40
gunzip -c /srv/nextcloud/backups/nextcloud-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 30
curl -sS https://<DOMAIN>/status.php
```

You should see: no output from the `gunzip` line, then a status object that still reads
`"installed":true`. Sign in again to be sure. That is a database deleted, rebuilt and refilled
while your files stayed where they were.

If you do not: `Access denied for user` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. `ERROR 1049 Unknown database`
means the volume was recreated without `.env` present, so check the file is still there. To
restore the files as well, untar the files archive back into /srv/nextcloud/html. Understand
what you are protecting: this is where your photos and documents live now, and the database is
the only thing that knows which file belongs to whom.

## 9. Updating later

New versions are listed at https://github.com/nextcloud/server/releases. Take all three backup
artifacts first, then edit both `image:` lines in /srv/nextcloud/compose.yml to the new tag and
its digest. They are the same image and they have to move together.

```bash
cd /srv/nextcloud
docker compose pull
docker compose up -d
docker compose logs --tail 30 app
```

You should see: `Initializing nextcloud`, then `Upgrading nextcloud from ...`, then the server
starting, and no repeating restart.

If you do not: `Can't start Nextcloud because upgrading from ... is not supported` means you
skipped a major version. Put the old tag and digest back, run the same three commands, then
step through one major version at a time. Re-run the status check from step 7 before you call
the update done.

## 10. What will probably go wrong

The first `docker compose up -d` looks like a failed install for several minutes. Caddy answers
`502` throughout, because the container is still unpacking 600 MB of PHP into
/srv/nextcloud/html and then waiting on MariaDB, and I spent that stretch certain the
trusted-domain setting was wrong. It was not. Past ten minutes of `502`, suspect the hostname:
the symptom is `Access through untrusted domain` on the page, `NEXTCLOUD_TRUSTED_DOMAINS` is
read only at first install so editing .env later does nothing, and the fix is
`docker compose exec -u www-data -T app php /var/www/html/occ config:system:set trusted_domains
1 --value=<DOMAIN>`.

## 11. Out of scope

- Do not configure SMTP. On a personal install all it buys is password-reset mail, and you know
  your own password.
- Do not install Collabora Online or ONLYOFFICE. Each is a second service with its own
  container and memory floor.
- Do not use the updater in the web interface. The image is the update path, and that updater
  rewrites the directory the image owns.
- Do not enable the preview, antivirus or full-text-search apps. Each turns a quiet box into a
  busy one.
