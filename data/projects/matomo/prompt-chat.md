This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Matomo 5.12.0 on a VPS where Prompt Zero is done: `ssh vps` works, Docker
and Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a
step says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at
the box.

Read this before step 1. That hostname becomes Matomo's trusted host and goes inside the
tracking snippet you paste on every page you measure, so moving it later means editing all of
them and telling Matomo about the new name.

## 1. Preflight

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

You should see: at least `2048` MB available, at least `10` G free, `amd64` or `arm64`, and
your server's IP on the last line. Those are upstream's figures for a site tracking 100,000
page views a month, and Matomo grows into them rather than out of them.

If you do not: an empty last line means the A record does not exist yet. Add it, wait a minute,
run `dig +short <DOMAIN>` again. Caddy cannot get a certificate for a hostname that does not
resolve, and failed attempts count against a rate limit you cannot see. Under 2048 MB of RAM,
stop and resize the box: PHP and MariaDB will both start on less and the archiving run in step
7 is where it falls over, which is a much worse place to find out.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/matomo /srv/matomo/backups
sudo install -d -m 750 /srv/matomo/matomo
sudo install -d -m 700 /srv/matomo/mariadb
ls -la /srv/matomo
```

You should see: `backups` owned by you, `matomo` at mode `drwxr-x---` and `mariadb` at mode
`drwx------`, both owned by root.

If you do not: leave those two owned by root on purpose. The Matomo image unpacks its whole PHP
tree into `matomo` and chowns it to www-data the first time it starts, MariaDB chowns its own
data directory, and a directory you have already chowned to yourself makes one of them refuse
to initialise.

## 3. Secrets

Two secrets, both generated here on the server: the password for the `matomo` database user and
the MariaDB root password. Matomo ships no account and no admin token of its own, because the
browser wizard in step 7 creates the first user.

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

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/matomo/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten both
passwords, which is fine before the database exists and a problem afterwards: MariaDB keeps the
password it was created with, so a changed `MARIADB_PASSWORD` on an existing data directory
produces an access-denied line in the Matomo log rather than anything about passwords.

Do not paste that file, either password, or any command output containing them into this chat
window. Docker Compose reads the file itself for the `${...}` substitutions in compose.yml, and
the wizard's database form arrives with the password already filled in and masked, so you never
have to type it or look at it.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

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

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/matomo/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/matomo/compose.yml` and paste again in one go. The third service is the one people
skip and then regret. Upstream documents scheduled archiving as a script that runs every hour,
and without it Matomo computes its reports while somebody sits watching a page load.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

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

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-matomo /etc/caddy/Caddyfile`, reload,
and paste again. Caddy terminates TLS and speaks plain http to the container, which is why step
7 writes `assume_secure_protocol` into Matomo's config: without it Matomo would decide the
request came in over http, and `force_ssl` would send the browser round in a redirect loop.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8119` or `3306`.

If you do not: delete anything for `8119` or `3306` with `sudo ufw delete allow 8119`. 8119 is
bound to 127.0.0.1 by the compose file and 3306 is never published at all, so the database has
no host port a firewall rule could apply to. `Status: inactive` is a different problem: Prompt
Zero left this firewall enabled, so something has turned it off since, and `sudo ufw enable`
puts it back before you go any further.

## 7. Start and verify

The first start unpacks about 200 MB of PHP into /srv/matomo/matomo, so give it time.

```bash
cd /srv/matomo
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' https://<DOMAIN>/index.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS https://<DOMAIN>/ | grep -c 'Matomo is libre software used to analyze traffic from your visitors'
```

You should see: the loop reaching `200`, then `1` from the grep, which is the installer's
welcome page answering on your hostname.

If you do not: run `docker compose logs --tail 20 db` first, because a database that never
reports healthy holds up everything after it, and `docker compose logs --tail 40 app` second. A
`502` that never clears is step 5. A running container is not success.

Now write the settings the wizard never asks about, before anybody uses it. Matomo reads this
file before config.ini.php, so the wizard cannot overwrite it. Replace `<DOMAIN>` on the
`trusted_hosts` line before you paste.

```bash
cd /srv/matomo
docker compose exec -T -u www-data app sh -c 'cat > /var/www/html/config/common.config.ini.php' <<'EOF'
[General]
; Caddy terminates TLS and speaks plain http to the container, so Matomo is
; told the request arrived over https before it builds any https link.
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

You should see: `200`.

If you do not: a `500` means a typo in that file. Read it back with
`docker compose exec -T app cat /var/www/html/config/common.config.ini.php`, fix the line, and
run the curl again. A redirect loop in a browser means `assume_secure_protocol` did not land,
so check that the file really contains it.

Now open https://<DOMAIN> in a browser and work through the wizard. The database screen is
already filled in and its password masked, so keep the adapter on its default and press
Next. The superuser you create on the `Super User` screen is the only account this install
has, and it goes in your password manager before you click past it. The website you name on
the last screen is what the tracking snippet Matomo prints at the end belongs to.

When the wizard is finished, prove it, back in the terminal:

```bash
cd /srv/matomo
curl -sS 'https://<DOMAIN>/index.php?module=Installation&action=welcome' | grep -c 'Matomo is already installed'
docker compose exec -T -u www-data app php /var/www/html/console config:get --section=General --key=trusted_hosts | grep -c '<DOMAIN>'
curl -sS -o /dev/null -w '%{http_code}\n' 'https://<DOMAIN>/matomo.php?idsite=1&rec=1&action_name=selfhost-check&url=https%3A%2F%2Fexample.com%2F'
sleep 5
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from matomo_log_visit" "$MARIADB_DATABASE"'
docker compose exec -T -u www-data app php /var/www/html/console core:archive --no-ansi | tail -5
```

You should see, in order: `1`, `1`, `200`, a count of `1` or more, and a last block of output
ending in `Done archiving!`.

If you do not: the first `1` is the one that matters most. It means the installer now answers
`Error: Matomo is already installed.` to anyone who finds that URL, which is the difference
between a finished install and a setup wizard sitting open on a public hostname. A `0` there
means the wizard never completed, so go back to the browser. The second `1` reads Matomo's own
merged config and proves the trusted-host list names your hostname and nothing else. A count of
`0` means the tracker accepted your request and dropped it: read
`docker compose logs --tail 40 app`. If the archive run ends in an error instead, your reports
will quietly stop refreshing while the tracker keeps recording, so fix it before you trust
anything on the dashboard.

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

You should see: two files, both a few tens of kilobytes on a fresh install. Nothing goes
offline, because `--single-transaction` snapshots a running InnoDB database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means `mariadb-dump`
failed and the shell created the file anyway. Run the dump line without `| gzip` to read the
error.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/matomo
scp vps:/srv/matomo/backups/* ~/backups/matomo/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/matomo/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:`
prefix only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is one test visit:

```bash
cd /srv/matomo
docker compose down
sudo rm -rf /srv/matomo/mariadb
sudo install -d -m 700 /srv/matomo/mariadb
docker compose up -d db
sleep 40
gunzip -c /srv/matomo/backups/matomo-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 20
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from matomo_log_visit" "$MARIADB_DATABASE"'
```

You should see: the same count you saw in step 7, from a database that was deleted and rebuilt.

If you do not: `Access denied` means the database container had not finished initialising, so
wait longer and run the `gunzip` line again. The `config` directory was never touched by this
exercise, which is why the site came back without it: if you ever lose that directory too,
untar the config archive into /srv/matomo before starting anything, because Matomo will not run
at all without it and MariaDB reads its password from `.env` the moment it initialises.

## 9. Updating later

New versions are listed at https://github.com/matomo-org/matomo/releases. Take both backup
artifacts first, then edit both image lines in /srv/matomo/compose.yml to the new tag and its
digest: `app` and `archive` run the same image, and a mismatch runs last month's archiver on
this month's schema.

```bash
cd /srv/matomo
docker compose pull
docker compose up -d
docker compose exec -T -u www-data app php /var/www/html/console core:update --no-interaction
docker compose logs --tail 30 app
```

You should see: `core:update` reporting the database upgrade and finishing, then a normal
Apache start with no repeating restart.

If you do not: put the old tag and digest back on both image lines and run the same commands.
Matomo does not migrate its schema on boot, which is what `core:update` is for, so an update
that skips it leaves a new binary reading an old database. Re-run the tracker and archive
checks from step 7 before you call the update done.

## 10. What will probably go wrong

The dashboard will be empty on the day you install it and you will decide tracking is broken.
Mine was. Step 7 turned off the archiving a page load used to trigger, so nothing is computed
until the archive container's hourly pass, which can be an hour away. The raw hits are in the
database the whole time. Before touching anything, run
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
  city database from its own Geolocation screen, later, if you want it.
