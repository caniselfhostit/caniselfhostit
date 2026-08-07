You are Claude Code on the user's machine. The user has completed Prompt Zero: `ssh vps` works,
Docker and Caddy are installed, the firewall is default-deny.

Run every command in this prompt on the server over `ssh vps` unless the step says otherwise.

Install Mautic 7.1.3 on that server, reachable at https://<DOMAIN>, behind the existing Caddy
with automatic TLS.

## 1. Preflight

If `<DOMAIN>` is still literal, ask the user for the hostname and for `<ADMIN_EMAIL>` once and
stop until they answer. The A record must already point here. Say why when you ask: that
hostname becomes Mautic's Site URL, and every link, unsubscribe address and tracking pixel in
every message they send is built from it.

Mautic, its cron container and MariaDB need 2048 MB of RAM available and 10 GB free on /srv.
The image caps each PHP process at 512 MB; this install raises both to 768 MB. Both images
publish amd64 and arm64.

```bash
free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}'
df -BG --output=avail /srv | tail -1
dpkg --print-architecture
dig +short <DOMAIN>
```

If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers and stop. Do
not install and hope. If `dig +short` prints nothing, print that and stop: Caddy cannot certify
a name nobody can resolve.

## 2. Layout

```bash
sudo install -d -m 750 -o $(id -u) -g $(id -g) /srv/mautic /srv/mautic/backups
sudo install -d -m 750 /srv/mautic/config /srv/mautic/logs /srv/mautic/media /srv/mautic/media/files /srv/mautic/media/images
sudo install -d -m 700 /srv/mautic/mariadb
ls -la /srv/mautic
```

Assert: `backups` owned by the login user, `config`, `logs` and `media` at mode `750`, and
`mariadb` at `700`. Leave those four to their containers: the image chowns its mounts to
www-data at every start, MariaDB chowns its own data directory, and a directory claimed
first is how both fail.

## 3. Secrets

Three: the `mautic` database password, the MariaDB root password, and the one for the
administrator account step 7 creates. Print none of them and keep all three out of your summary
and every log line.

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

Assert: mode `-rw-------` and the login user's name twice. The admin one also reaches the web
container, because step 7's installer takes it from there rather than off a command line, where
it would sit in shell history and `ps` output.

## 4. compose.yml

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

Assert: `compose OK`. Upstream's own example runs the cron role as its own container. Without
it, segments never refresh and campaign steps never fire.

## 5. Caddy and TLS

Append the block below, `<DOMAIN>` replaced by the real hostname. Copy the file first: a
syntax error here takes down every other site on the box.

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

Assert: both exit 0. If validate fails, restore /etc/caddy/Caddyfile.before-mautic, reload and
report the objection. Caddy gets the certificate on the first request and renews it.

## 6. Firewall

Two ports open, both Caddy's, idempotent on a Prompt Zero box:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status verbose
```

80/tcp answers the ACME challenge and redirects to HTTPS, 443/tcp is the only way in, 443/udp
is HTTP/3. 8161 stays closed because compose binds it to loopback, 3306 because the database
gets no host port, and nothing opens for mail. Assert: `Status: active`, rules for 80, 443/tcp
and 443/udp, nothing for 8161 or 3306.

## 7. Start and verify

The first start pulls about 1.5 GB. Mautic ships with no schema and no account; the last line
creates both.

```bash
cd /srv/mautic
docker compose pull
docker compose up -d
for i in $(seq 1 40); do state=$(docker inspect -f '{{.State.Health.Status}}' mautic-web 2>/dev/null || echo none); echo "$i $state"; [ "$state" = healthy ] && break; sleep 10; done
docker compose exec -T -u www-data -w /var/www/html mautic_web sh -c 'php ./bin/console mautic:install https://<DOMAIN> --admin_email <ADMIN_EMAIL> --admin_password "$MAUTIC_ADMIN_PASSWORD" --force'
```

Assert: the loop ends on `healthy` and the install prints `Install complete`. If not, stop, run
`docker compose logs --tail 40 mautic_web` and `docker compose logs --tail 20 db`, and name the
likely step: a database that never reports healthy is step 2, and so is an entrypoint refusing a
directory it cannot chown. A running container is not success.

Now the setting the installer never asks about, which upstream calls mandatory behind a TLS
proxy, and the checks:

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

Assert all four, printing what you received. The curl prints `200` and the grep `1`. The
crontab grep prints `1`, so the cron container holds the schedule that keeps segments and
campaigns moving; a `0` means it is still waiting on the install, so restart `mautic_cron` and
run the line again. The last line prints `console OK`: the console booted, read the
installer's config and reached the database. It lists no segments; a fresh install has none.

The first screen at https://<DOMAIN>/s/login shows `Username or email` in the first field, a
`Password` field, a `Keep me logged in` box and a `Login` button.

STOP: tell the user to do these three things and wait. Do not continue until they confirm.

- Read the administrator password with `sudo grep MAUTIC_ADMIN_PASSWORD /srv/mautic/.env`, put
  it in their password manager, and log in at https://<DOMAIN>/s/login as `admin`.
- Settings -> Configuration -> Email Settings: the mailer ships pointed at
  `smtp://localhost:1025`, which is nothing, and the from-address at `email@yoursite.com`.
  Replace both with their relay's and an address on a domain they own, then use Test connection
  before saving.
- Settings -> Configuration -> System Settings: list every site they mean to drop the tracking
  script on under CORS Valid Domains. Cross-origin calls are restricted by default, so a form
  on an unlisted domain fails quietly.

Once they confirm, check the mail settings moved:

```bash
cd /srv/mautic
docker compose exec -T -u www-data -w /var/www/html mautic_web php -r 'include "config/local.php"; $d=$parameters["mailer_dsn"]??""; $f=$parameters["mailer_from_email"]??""; echo ($d===""||str_contains($d,"localhost:1025")?"DSN default":"DSN moved"),"\n",($f===""||$f==="email@yoursite.com"?"FROM default":"FROM moved"),"\n";'
```

Assert: `DSN moved` and `FROM moved`. It prints verdicts, never values: the DSN now
carries the relay password. Either `default` means every campaign fails at the moment of
sending, a step-7 failure and not a step-10 mystery.

## 8. First backup and restore

Two artifacts: the database holds contacts, consent, segments, campaigns and recorded visits;
the config archive rebuilds the service around it, including the local.php with the installer's
secret key.

```bash
cd /srv/mautic
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > /srv/mautic/backups/mautic-db-$(date +%F).sql.gz
sudo tar -czf /srv/mautic/backups/mautic-config-$(date +%F).tar.gz -C /srv/mautic compose.yml .env config media -C /etc/caddy Caddyfile
ls -lh /srv/mautic/backups/
```

Assert: both exist and are non-empty; print both sizes. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database. Both archives carry live
credentials, local.php the relay's and .env the database's; tell the user that.

A backup on the same disk as the data is not a backup. Run this from the user's machine, not
the server:

```bash
mkdir -p ~/backups/mautic
scp vps:/srv/mautic/backups/* ~/backups/mautic/
```

To restore: `docker compose down`, `sudo rm -rf /srv/mautic/mariadb`, recreate it as in step 2,
untar the config archive into /srv/mautic, `docker compose up -d db`, wait 40 seconds for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d` and re-run step 7's asserts. The opt-in and its timestamp for every
contact live in that database, and a list restored from a backup nobody took is a list they may
no longer mail.

## 9. Updating later

New versions are at https://github.com/mautic/mautic/releases. Take both backups first, then
edit both Mautic image lines in compose.yml to the new tag and digest:

```bash
cd /srv/mautic
docker compose pull
docker compose up -d
docker compose logs --tail 40 mautic_web
```

The web container runs its own database migrations on the way up, so watch that log until
they settle, then re-run step 7's asserts. Major versions carry UPGRADE notes; read those
first.

## 10. What will probably go wrong

Nothing appears to work for fifteen minutes. I imported contacts, built a segment
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
