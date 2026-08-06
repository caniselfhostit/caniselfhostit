You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Nextcloud 34.0.2, with the MariaDB and Redis it needs, under ~/selfhost/nextcloud,
answering at http://localhost:8099.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install at all.
Nothing but this computer can reach the server, so the phone app and the sync client that make
Nextcloud worth running sync only from here, and only while the machine is awake.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. This needs 2048 MB of RAM available and
10 GB free on the home disk, and all three images publish amd64 and arm64. If RAM is under
2048 MB or free disk under 10 GB, print both numbers and stop.

## 2. Docker

Check before installing anything:

```bash
docker info >/dev/null 2>&1 && echo "docker OK" || echo "docker MISSING"
docker compose version 2>/dev/null || true
```

If that printed `docker OK` and a compose version, skip to step 3.

Otherwise, install Docker for the OS step 1 detected:

- macOS: if `command -v brew` succeeds, run `brew install --cask docker`. If there is no
  Homebrew, STOP: tell the user to download Docker Desktop from
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they
  confirm. Either way, then STOP: tell the user to open Docker Desktop once, accept its
  terms, and wait for the whale icon to say it is running. Do not continue until they
  confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and
  install it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may
  ask for a reboot; if it does, STOP and tell the user to reboot and come back, this
  prompt resumes at this step. Then STOP: have the user open Docker Desktop, accept its
  terms, and confirm it says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt
  repository, with its signing key saved to a file first, never piped into a shell. The
  fence is guarded, a no-op on anything but a Linux with apt:

```bash
if [ "$(uname -s)" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER"
fi
```

  Adding the user to the docker group is root-equivalent on this machine; say that to the
  user in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/nextcloud/backups
ls -la ~/selfhost/nextcloud
```

Assert: `backups`, owned by the user. There is no `data` folder: step 5 keeps the Nextcloud
tree and the database in volumes Docker manages, because each image chowns its directory to a
uid Docker Desktop cannot grant on a bind mount.

## 4. Secrets

Three secrets: the `nextcloud` database password, the MariaDB root password, and the first
administrator's password. Generate all three here, print none, and keep them out of your
summary and any log line.

```bash
umask 077
cat > ~/selfhost/nextcloud/.env <<EOF
NEXTCLOUD_TRUSTED_DOMAINS=localhost:8099
OVERWRITECLIURL=http://localhost:8099
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -hex 24)
MYSQL_PASSWORD=$(openssl rand -hex 32)
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/nextcloud/.env
umask 022
ls -l ~/selfhost/nextcloud/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl. On Windows those mode bits are advisory and
the real boundary is the user's own account. `admin` is fixed because a Nextcloud account
cannot be renamed later.

## 5. compose.yml

```bash
cat > ~/selfhost/nextcloud/compose.yml <<'EOF'
# Nextcloud · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image README ..... https://github.com/nextcloud/docker
#   requirements ..... https://docs.nextcloud.com/server/34/admin_manual/installation/system_requirements.html
#
# Four services under ~/selfhost/nextcloud/, so the paths here are relative.
# Named volumes for both data directories, because the Nextcloud image chowns
# /var/www/html to www-data and MariaDB chowns /var/lib/mysql to its own uid,
# and Docker Desktop's Windows file sharing grants neither on a bind mount.
# `cron` is the app image with entrypoint /cron.sh, mounting the same volume as
# `app`. Nothing terminates TLS: http, loopback, and localhost always trusted.
# Digests read 2026-08-05; all three images publish amd64 and arm64.
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
      - nextcloud-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: nextcloud-redis
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

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
      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_TRUSTED_DOMAINS}
      OVERWRITEPROTOCOL: http
      OVERWRITECLIURL: ${OVERWRITECLIURL}
    volumes:
      - nextcloud-html:/var/www/html
    ports:
      # Loopback only: no other device on the wifi can reach 8099.
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
    entrypoint: /cron.sh
    environment:
      REDIS_HOST: redis
      OVERWRITEPROTOCOL: http
      OVERWRITECLIURL: ${OVERWRITECLIURL}
    volumes:
      - nextcloud-html:/var/www/html
    depends_on:
      app:
        condition: service_started

volumes:
  nextcloud-db:
  nextcloud-html:
EOF
cd ~/selfhost/nextcloud && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Four services, one published port, two named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8099 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not the internet.

```bash
grep -n '127.0.0.1' ~/selfhost/nextcloud/compose.yml
```

Assert: one line, `- "127.0.0.1:8099:80"`. MariaDB and Redis publish no host port.

## 7. Start and verify

The first start is slow: the entrypoint unpacks 600 MB of Nextcloud into its volume and waits
for MariaDB before installing, because step 4 wrote the admin password first.

```bash
cd ~/selfhost/nextcloud
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8099/status.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8099/status.php
curl -sSL -o /tmp/nc-first-screen.html -w '%{http_code} %{url_effective}\n' http://localhost:8099/
grep -c 'id="body-login"' /tmp/nc-first-screen.html
docker compose exec -u www-data -T app php /var/www/html/occ config:system:get memcache.locking
docker compose exec -u www-data -T app php -f /var/www/html/cron.php && echo "cron OK"
```

Assert all five, printing what you got. The loop ends on `200`; the status response
contains `"installed":true` and `"versionstring":"34.0.2"`; the third line prints `200` and a
URL ending in `/login` and the grep prints `1`, which say the setup wizard is gone; the occ call
prints `\OC\Memcache\Redis`; the last prints `cron OK`. If any misses, stop, run
`docker compose logs --tail 40 app`, and name the cause: a database never reporting healthy
is step 4, a log still moving wants more time, `port is already allocated` means something
else holds 8099 (`lsof -nP -iTCP:8099 -sTCP:LISTEN`, or `netstat -ano | findstr :8099`). A
running container is not success.

The first screen at http://localhost:8099 shows the heading `Log in to Nextcloud` above an
`Account name or email` field and a `Password` field.

STOP: tell the user to read their password with
`grep NEXTCLOUD_ADMIN_PASSWORD ~/selfhost/nextcloud/.env`, put it in their password manager,
then sign in at http://localhost:8099 as `admin`. Wait. Do not continue until they confirm.

## 8. First backup and restore

Three artifacts: the database, the user files, and the two files that rebuild the service.
Both volumes are Docker's, so the copies come out through the containers.

```bash
cd ~/selfhost/nextcloud
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --on
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/nextcloud/backups/nextcloud-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - config data > ~/selfhost/nextcloud/backups/nextcloud-files-$(date +%F).tar.gz
tar -C ~/selfhost/nextcloud -czf ~/selfhost/nextcloud/backups/nextcloud-config-$(date +%F).tar.gz compose.yml .env
docker compose exec -u www-data -T app php /var/www/html/occ maintenance:mode --off
ls -lh ~/selfhost/nextcloud/backups/
```

Assert: three files, none empty, sizes printed. Maintenance mode makes the database and the
files one moment, about a minute here.

All three sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a synced folder or a USB
stick, and copy all three there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert:
the user confirms all three names are there. If they have none, say plainly this install has no
backup.

To restore: untar the config archive into ~/selfhost/nextcloud first, so .env is back before
any container starts and MariaDB initialises with the right password. Then
`docker compose down -v`, the one place `-v` belongs because it drops both old volumes on
purpose, `docker compose up -d db`, wait 30 seconds for healthy, and pipe `gunzip -c` on the
`.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Then `docker compose up -d`, wait for `/status.php`, and unpack the files with
`gunzip -c backups/nextcloud-files-<date>.tar.gz | docker compose exec -T app tar -C /var/www/html -xf -`.
Restart, sign in, open a file.

## 9. Updating later

Releases are at https://github.com/nextcloud/server/releases. Back up first, then edit both
`image:` lines in ~/selfhost/nextcloud/compose.yml to the new tag and digest; they are one
image and move together.

```bash
cd ~/selfhost/nextcloud
docker compose pull
docker compose up -d
docker compose logs --tail 30 app
```

Nextcloud upgrades one major version at a time and refuses to skip one. Watch the log until it
settles, then re-run step 7's check.

## 10. What will probably go wrong

Connection refused, twice, for different reasons. The first was forty seconds after
`docker compose up -d`: the container was still unpacking 600 MB of PHP into its volume and had
not started Apache. The second was after a reboot, and that one was real: Docker Desktop had
not started with the session, so nothing was listening. `restart: unless-stopped` acts only
once the Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/nextcloud && docker compose up -d` before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8099 to 0.0.0.0 so a phone can reach it. That puts the user's file store on
  every network they join, unencrypted.
- Do not configure SMTP. On a single-user install it only buys password-reset mail.
- Do not install Collabora Online or ONLYOFFICE, and do not enable the preview, antivirus or
  full-text-search apps. Each turns a quiet laptop warm.
