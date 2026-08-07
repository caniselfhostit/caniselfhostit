This path is slower: you paste every command yourself, and there is nobody watching the output
but you. If you can run Claude Code, use the other tab.

You are installing Mautic 7.1.3 on a VPS where Prompt Zero is done: `ssh vps` works, Docker and
Caddy are installed, the firewall is default-deny. Run everything over `ssh vps` unless a step
says otherwise, and replace `<DOMAIN>` with the hostname whose A record already points at the
box, and `<ADMIN_EMAIL>` with the address your one administrator account will carry.

Read this before step 1, because it is the decision here you cannot undo. `<DOMAIN>` becomes
Mautic's Site URL, and every link, unsubscribe address and tracking pixel in every message you
send is built from it. Change it later and the links in mail people have already received stop
resolving.

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
run `dig +short <DOMAIN>` again, because Caddy cannot get a certificate for a hostname that
does not resolve and failed attempts count against a rate limit you cannot see. Under 2048 MB
of RAM, stop and resize the box rather than installing: this is PHP running in two containers
plus a database, and the OOM killer arrives during your first import.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mautic /srv/mautic/backups
sudo install -d -m 750 /srv/mautic/config /srv/mautic/logs /srv/mautic/media /srv/mautic/media/files /srv/mautic/media/images
sudo install -d -m 700 /srv/mautic/mariadb
ls -la /srv/mautic
```

You should see: seven directories, `backups` owned by you, `mariadb` at `drwx------` owned by
root.

If you do not: leave the last four to their containers on purpose. The Mautic image starts as
root, checks its four mounts exist and chowns them to www-data, and MariaDB chowns its own data
directory. A directory you have already chowned to yourself is the usual reason one of them
refuses to initialise.

## 3. Secrets

Three secrets, all generated here on the server, all going straight into a file only you can
read: the `mautic` database password, the MariaDB root password, and the password for the
administrator account step 7 creates.

```bash
umask 077
cat > /srv/mautic/.env <<EOF
MARIADB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
MAUTIC_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 /srv/mautic/.env
umask 022
ls -l /srv/mautic/.env
```

You should see: mode `-rw-------`, your own username twice, and the path.

If you do not: a mode of `-rw-r--r--` means `umask 077` did not take effect, which happens if
you pasted the lines separately in different shells. Run `chmod 600 /srv/mautic/.env` and carry
on. If the file already existed from an earlier attempt, this block has now overwritten all
three, which is fine before the database exists and a problem afterwards: MariaDB keeps the
password it was created with, so a changed one on an existing volume shows up as an access
denied error in the Mautic log rather than as anything about passwords.

Do not paste that file, any of the three values, or any command output containing them into
this chat window. Read the administrator password when you need it with
`sudo grep MAUTIC_ADMIN_PASSWORD /srv/mautic/.env`, in your own terminal, and put it straight
into your password manager. Know one more place it lives: step 7 hands it to the web container
as an environment variable, so `docker inspect` on this box can read it, the same boundary the
docker group already crosses.

## 4. compose.yml

Paste the whole block at once, including the last two lines.

```bash
cat > /srv/mautic/compose.yml <<'EOF'
# Mautic · the deterministic fallback. Authored by caniselfhostit from the
# upstream documentation, not copied from a repository:
#   image README ....... https://github.com/mautic/docker-mautic
#   container roles .... https://github.com/mautic/docker-mautic/blob/main/common/docker-entrypoint.sh
#   cron jobs .......... https://docs.mautic.org/en/7.1/configuration/cron_jobs.html
#
# `mautic_web` is Apache with PHP; `mautic_cron` is the same image under
# DOCKER_MAUTIC_ROLE=mautic_cron, which waits for the install then runs the
# crontab it ships: segments, campaigns and triggers every 15 minutes. No
# worker container: 7.1.3 defaults both messenger transports to sync://.
# MariaDB rather than upstream's mysql:lts, both documented. Every ${...}
# comes from /srv/mautic/.env, mode 600. Digests read 2026-08-06; amd64 and
# arm64 both published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-mautic-env: &mautic-env
  MAUTIC_DB_HOST: db
  MAUTIC_DB_DATABASE: mautic
  MAUTIC_DB_USER: mautic
  MAUTIC_DB_PASSWORD: ${MARIADB_PASSWORD}
  PHP_INI_VALUE_MEMORY_LIMIT: 768M

x-mautic-volumes: &mautic-volumes
  - /srv/mautic/config:/var/www/html/config
  - /srv/mautic/logs:/var/www/html/var/logs
  - /srv/mautic/media/files:/var/www/html/docroot/media/files
  - /srv/mautic/media/images:/var/www/html/docroot/media/images

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: mautic-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: mautic
      MARIADB_USER: mautic
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - /srv/mautic/mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other containers.

  mautic_web:
    image: mautic/mautic:7.1.3-apache@sha256:373a3de08dfce296e31fe0b7caf269594c43020454628f445c169990b9af4d5e
    container_name: mautic-web
    restart: unless-stopped
    environment:
      <<: *mautic-env
      DOCKER_MAUTIC_ROLE: mautic_web
      # Read by step 7's install command, by nothing in the image.
      MAUTIC_ADMIN_PASSWORD: ${MAUTIC_ADMIN_PASSWORD}
    volumes: *mautic-volumes
    healthcheck:
      test: ["CMD-SHELL", "curl -sS -o /dev/null http://127.0.0.1/ || exit 1"]
      start_period: 30s
      interval: 10s
      retries: 30
    ports:
      # Loopback only: the host's Caddy is the only thing that reaches 8161.
      - "127.0.0.1:8161:80"
    depends_on:
      db:
        condition: service_healthy

  mautic_cron:
    image: mautic/mautic:7.1.3-apache@sha256:373a3de08dfce296e31fe0b7caf269594c43020454628f445c169990b9af4d5e
    container_name: mautic-cron
    restart: unless-stopped
    environment:
      <<: *mautic-env
      DOCKER_MAUTIC_ROLE: mautic_cron
    volumes: *mautic-volumes
    depends_on:
      mautic_web:
        condition: service_healthy
EOF
cd /srv/mautic && docker compose config >/dev/null && echo "compose OK"
```

You should see: `compose OK` and nothing else.

If you do not: `env file /srv/mautic/.env not found` means step 3 did not write the file.
`services must be a mapping` means the indentation was lost between the page and your terminal:
run `rm /srv/mautic/compose.yml` and paste again in one go. The third service is not optional.
Upstream's own example runs the cron role as its own container, and without it segments never
refresh and campaign steps never fire, which is a Mautic that looks installed and does nothing.

## 5. Caddy and TLS

This appends one site block to the Caddy config Prompt Zero installed. Replace `<DOMAIN>` in
the block with your hostname before you paste. The first line takes a copy, because a syntax
error here takes down every other site on the box.

```bash
sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.before-mautic
printf '\n' | sudo tee -a /etc/caddy/Caddyfile >/dev/null
sudo tee -a /etc/caddy/Caddyfile >/dev/null <<'EOF'
# Mautic · the Caddy site block for this service. Authored by caniselfhostit
# from https://docs.mautic.org/en/7.1/configuration/settings.html and
# https://caddyserver.com/docs/automatic-https
#
# Append this to /etc/caddy/Caddyfile with <DOMAIN> replaced by the hostname
# pointed at this box. That hostname is Mautic's Site URL, and every link and
# tracking pixel it writes into a message is built from it.

<DOMAIN> {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		-Server
	}

	# Caddy terminates TLS and adds X-Forwarded-For; step 7's trusted_proxies
	# list tells Mautic to believe it. 8161 is the loopback port compose
	# publishes here, not a container port and not in the firewall.
	reverse_proxy 127.0.0.1:8161
}
EOF
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

You should see: `Valid configuration` from validate, and no output at all from reload.

If you do not: run `sudo cp /etc/caddy/Caddyfile.before-mautic /etc/caddy/Caddyfile`, reload,
and paste again. Caddy gets the certificate on the first request and renews it on its own, so
there is nothing to schedule.

## 6. Firewall

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

You should see: `Status: active`, rules for `80/tcp`, `443/tcp` and `443/udp`, and no rule
mentioning `8161` or `3306`.

If you do not: delete anything for those two with `sudo ufw delete allow 8161`. 8161 is bound
to 127.0.0.1 by the compose file and 3306 is never published, so the database has no host port
a firewall rule could apply to. Nothing opens for mail either, because the connection to your
relay is outbound. `Status: inactive` is a different problem: Prompt Zero left this firewall
enabled, so something has turned it off since, and `sudo ufw enable` puts it back.

## 7. Start and verify

The first start pulls about 1.5 GB and chowns four mounted directories, so this takes minutes
rather than seconds. Mautic ships with no schema and no account, and the last command creates
both.

```bash
cd /srv/mautic
docker compose pull
docker compose up -d
for i in $(seq 1 40); do state=$(docker inspect -f '{{.State.Health.Status}}' mautic-web 2>/dev/null || echo none); echo "$i $state"; [ "$state" = healthy ] && break; sleep 10; done
docker compose exec -T -u www-data -w /var/www/html mautic_web sh -c 'php ./bin/console mautic:install https://<DOMAIN> --admin_email <ADMIN_EMAIL> --admin_password "$MAUTIC_ADMIN_PASSWORD" --force'
```

You should see: the loop counting up to `healthy`, then the installer printing its steps and
finishing on `Install complete`.

If you do not: `Mautic already installed` means a previous attempt got there, and you can move
on. A loop that never leaves `starting` is usually the database, so run
`docker compose logs --tail 20 db` first and `docker compose logs --tail 40 mautic_web` second.
An entrypoint complaining it cannot chown a volume is step 2 done wrong.

Now the setting the installer never asks about, which upstream calls mandatory behind a
TLS-terminating proxy, and the four checks that decide whether this worked:

```bash
cd /srv/mautic
docker compose exec -T -u www-data mautic_web sh -c 'cat >> /var/www/html/config/local.php' <<'EOF'
$parameters['trusted_proxies'] = ['127.0.0.1', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];
EOF
docker compose restart mautic_web
sleep 25
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/s/login
curl -sS https://<DOMAIN>/s/login | grep -c 'Username or email'
docker compose exec -T mautic_cron crontab -l -u www-data | grep -c 'mautic:segments:update'
docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:segments:update --no-ansi && echo "console OK"
```

You should see, in order: `200`, then `1`, then `1`, then `console OK`. That last command lists
no segments on a fresh install, because there are none yet; what it proves is that the command
line booted the app, read the config the installer wrote and reached the database.

If you do not: a `500` from the first curl is a typo in the line you appended, so read it back
with `docker compose exec -T mautic_web tail -3 /var/www/html/config/local.php`. A crontab grep
of `0` means the cron container is still waiting for the install to land: run
`docker compose restart mautic_cron`, wait a minute, and try that line again. Without it your
segments never update and your campaigns never fire, and nothing on the screen will tell you.

The first screen at https://<DOMAIN>/s/login shows `Username or email` in the first field, a
`Password` field, a `Keep me logged in` box and a `Login` button. Log in as `admin` with the
password from step 3. A green `docker compose ps` is not success; those four lines are.

Now three things only you can do, in the browser, under Settings -> Configuration:

- Email Settings: the mailer ships pointed at `smtp://localhost:1025`, which is nothing, and
  the from-address at `email@yoursite.com`. Replace both with your relay's host, port and
  credentials and an address on a domain you control, then use Test connection before saving.
- System Settings: list every website you mean to drop the tracking script on under CORS Valid
  Domains. Cross-origin calls are restricted by default, so a form on another domain fails
  quietly until it is listed.
- While you are there, set your own timezone and default from-name.

```bash
cd /srv/mautic
docker compose exec -T -u www-data -w /var/www/html mautic_web php -r 'include "config/local.php"; $d=$parameters["mailer_dsn"]??""; $f=$parameters["mailer_from_email"]??""; echo ($d===""||str_contains($d,"localhost:1025")?"DSN default":"DSN moved"),"\n",($f===""||$f==="email@yoursite.com"?"FROM default":"FROM moved"),"\n";'
```

You should see: `DSN moved` and `FROM moved`. The command prints those verdicts instead of the
values on purpose: the DSN now contains your relay's password, and neither this terminal's
scrollback nor this chat window is where that belongs.

If you do not: either `default` means every campaign you build will fail at the moment of
sending, with an error that talks about a connection rather than about configuration. Both
lines reading `default` means you have not saved the Configuration form yet, which is the same
problem with a different spelling.

## 8. First backup and restore

Two artifacts. The database holds contacts, consent, segments, campaigns and every recorded
visit. The config archive holds what rebuilds the service around it, including the local.php
the installer wrote the secret key into.

```bash
cd /srv/mautic
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/mautic/backups/mautic-db-$(date +%F).sql.gz
sudo tar -czf /srv/mautic/backups/mautic-config-$(date +%F).tar.gz -C /srv/mautic compose.yml .env config media -C /etc/caddy Caddyfile
ls -lh /srv/mautic/backups/
```

You should see: two files, the dump a few hundred kilobytes on a fresh install and the archive
smaller. Nothing goes offline: `--single-transaction` snapshots a running InnoDB database.

If you do not: a `.sql.gz` of about 20 bytes is an empty dump, which means the dump command
failed and the shell created the file anyway. Run it without `| gzip` to read the error. Both
archives carry live credentials, local.php the mail relay's and .env the database's, so keep
them where you keep a password-manager export.

A backup on the same disk as the data is not a backup. Run this one on your own machine, not
the server:

```bash
mkdir -p ~/backups/mautic
scp vps:/srv/mautic/backups/* ~/backups/mautic/
```

You should see: two files copied, and both listed by `ls -lh ~/backups/mautic/`.

If you do not: `Permission denied (publickey)` means you ran it on the server. The `vps:` prefix
only means something on your own machine, where the alias Prompt Zero created lives.

Now prove the restore, today, while the only thing at risk is an empty install:

```bash
cd /srv/mautic
docker compose down
sudo rm -rf /srv/mautic/mariadb
sudo install -d -m 700 /srv/mautic/mariadb
docker compose up -d db
sleep 40
gunzip -c /srv/mautic/backups/mautic-db-$(date +%F).sql.gz | docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
docker compose up -d
sleep 30
curl -sS -o /dev/null -w '%{http_code}\n' https://<DOMAIN>/s/login
```

You should see: no output from the restore itself, then `200` from the last command.

If you do not: `Access denied for user` means the database container had not finished
initialising, so wait longer and run the `gunzip` line again. Understand the stakes before you
skip this. The opt-in and its timestamp for every contact you ever collect live in that
database, and a list restored from a backup nobody took is a list you may no longer mail.

## 9. Updating later

New versions are at https://github.com/mautic/mautic/releases. Take both backup artifacts
first, then edit both Mautic `image:` lines in /srv/mautic/compose.yml to the new tag and its
digest, keeping the two identical.

```bash
cd /srv/mautic
docker compose pull
docker compose up -d
docker compose logs --tail 40 mautic_web
```

You should see: migration output, then Apache starting, and no repeating restart.

If you do not: put the old tag and digest back in both lines and run the same three commands.
The web container runs its own database migrations on the way up once the config names a
database and a site URL, so a container that keeps restarting is usually a migration that did
not finish. Re-run step 7's four checks before you call the update done, and read the UPGRADE
notes in the repository before jumping a major version.

## 10. What will probably go wrong

Nothing appears to work for fifteen minutes. I imported a handful of contacts, built a segment
that should have matched all of them, watched it sit at zero, and started re-reading the
filters. The segment was fine. Segments are recomputed by `mautic:segments:update` in the cron
container on a quarter-hour schedule, campaigns five minutes behind that and triggers five
behind those, so the Mautic on screen is always a little behind what was done to it. When a
count looks stale, run step 7's `mautic:segments:update` line by hand and check the cron
container in `docker compose ps` first.

## 11. Out of scope

- Do not add the `mautic_worker` container or set `MAUTIC_MESSENGER_DSN_EMAIL`. That moves mail
  into a queue and makes this a four-service install to watch.
- Do not enable the commented-out crontab entries for inbound email, webhooks or integration
  syncing. Each wants credentials this install does not have.
- Do not install Marketplace plugins or themes here. They write into the container's code tree,
  which is not a mounted volume and dies at the next pull.
- Do not configure a MaxMind or IP-lookup service. Mautic records visits without one.
