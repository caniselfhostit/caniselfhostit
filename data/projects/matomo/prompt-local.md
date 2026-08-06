You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Matomo 5.12.0, with the MariaDB it stores visits in, under ~/selfhost/matomo, answering
at http://localhost:8119.

## 1. Preflight

Say this first, because it decides whether the user wants this install. The tracking snippet
Matomo hands them loads from http://localhost:8119, which means "this computer" in whoever's
browser reads it, so a public page carrying it records nobody else. They get an analytics
install counting what they open here. Then detect the OS and measure:

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
distribution ID and codename print next, for step 2. Matomo with MariaDB needs 2048 MB of RAM
available and 10 GB free on the home disk. If either floor is missed, print both and stop.

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
mkdir -p ~/selfhost/matomo/backups
ls -la ~/selfhost/matomo
```

Assert: `backups`, owned by the user. There is no `data` folder: the database and the web root
live in Docker-managed volumes, because both images chown their directory to a uid a Windows
bind mount cannot grant.

## 4. Secrets

Two secrets: the `matomo` database user's password and the MariaDB root password. Matomo ships
no account of its own; the wizard in step 7 makes the first user. Generate both here, print
neither, keep both out of your summary and any log line.

```bash
umask 077
cat > ~/selfhost/matomo/.env <<EOF
MARIADB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/matomo/.env
umask 022
ls -l ~/selfhost/matomo/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl. On Windows those mode bits are advisory:
NTFS does not enforce them, and the real boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/matomo/compose.yml <<'EOF'
# Matomo · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image README ....... https://github.com/matomo-org/docker
#   docker install FAQ . https://matomo.org/faq/how-to-install/install-matomo-with-docker/
#   archiving cron ..... https://matomo.org/faq/on-premise/how-to-set-up-auto-archiving-of-your-reports/
#
# Three services on the computer you are sitting at. Both data mounts are named
# volumes, not relative binds: MariaDB and the Matomo image each chown their
# directory to a uid of their own, which Docker Desktop's Windows file sharing
# cannot grant on a home-directory bind mount. Every ${...} comes from ./.env,
# mode 600. Digests read 2026-08-06.
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
      - matomo-db:/var/lib/mysql
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
      # These six only prefill the wizard's database form, once: after it the
      # credentials live in config.ini.php and nothing reads these again.
      MATOMO_DATABASE_HOST: db
      MATOMO_DATABASE_ADAPTER: mysql
      MATOMO_DATABASE_TABLES_PREFIX: matomo_
      MATOMO_DATABASE_USERNAME: matomo
      MATOMO_DATABASE_PASSWORD: ${MARIADB_PASSWORD}
      MATOMO_DATABASE_DBNAME: matomo
      PHP_MEMORY_LIMIT: 512M
    volumes:
      - matomo-html:/var/www/html
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1/index.php || exit 1"]
      interval: 10s
      retries: 24
    ports:
      # Loopback only: no other device on the wifi can reach 8119.
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
      - matomo-html:/var/www/html
    entrypoint: ["/bin/sh", "-c", "while true; do [ -s /var/www/html/config/config.ini.php ] && php /var/www/html/console core:archive --no-ansi; sleep 3600; done"]
    depends_on:
      app:
        condition: service_started

volumes:
  matomo-db:
  matomo-html:
EOF
cd ~/selfhost/matomo && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, nothing public to
attest, nothing published past loopback to close. Browsers treat http://localhost as a secure
context, so pages needing crypto still work. 8119 is bound to 127.0.0.1: not the phone, not a
laptop on the wifi, not anyone. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/matomo/compose.yml
```

Assert: one line, `- "127.0.0.1:8119:80"`. MariaDB publishes no host port, so 3306 cannot show.

## 7. Start and verify

```bash
cd ~/selfhost/matomo
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8119/index.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8119/ | grep -c 'Matomo is libre software used to analyze traffic from your visitors'
docker compose exec -T -u www-data app sh -c 'cat > /var/www/html/config/common.config.ini.php' <<'INI'
[General]
; Reports come from the archive container, not from a page load.
enable_browser_archiving_triggering = 0
browser_archiving_disabled_enforce = 1
INI
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8119/index.php
```

Assert: the loop ends on `200`, the grep prints `1`, the last line prints `200`, all three
printed. The heredoc writes the setting the wizard never asks about into a file it cannot
overwrite; a `500` after it is a typo there. The first start unpacks 200 MB of PHP, so let the
loop run out. On a miss read `docker compose logs --tail 40 app` and
`docker compose logs --tail 20 db`: a database that never reports healthy is step 4, and
`port is already allocated` means something else holds 8119. A running container is not
success.

STOP: tell the user to open http://localhost:8119, work through the wizard, and wait. Do
not continue until they confirm. Tell them the database screen is filled in and masked, so
they keep the adapter on its default and press Next, and the superuser they create is this
install's only account and goes in their password manager now. Then prove the wizard is
closed:

```bash
cd ~/selfhost/matomo
curl -sS 'http://localhost:8119/index.php?module=Installation&action=welcome' | grep -c 'Matomo is already installed'
curl -sS -o /dev/null -w '%{http_code}\n' 'http://localhost:8119/matomo.php?idsite=1&rec=1&url=https%3A%2F%2Fexample.com%2F'
sleep 5
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from matomo_log_visit" "$MARIADB_DATABASE"'
docker compose exec -T -u www-data app php /var/www/html/console core:archive --no-ansi | tail -5
```

Assert all four, printing what you got. The grep prints `1`, the security assert here: the
wizard now refuses anyone who reaches that URL. The tracker returns `200`. The count is `1` or
more, a tracking request that became a row. The archive run ends with `Done archiving!`, and a
`0` count means the tracker dropped it: read `docker compose logs --tail 40 app`.

The first screen at http://localhost:8119 now shows the heading `Sign in` above
`Username or e-mail`, `Password` and a `Lost your password?` link.

## 8. First backup and restore

Three artifacts: the database, Matomo's `config` directory, which holds the credentials and
salt inside a volume, and the two files here that rebuild the service.

```bash
cd ~/selfhost/matomo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > backups/matomo-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - config > backups/matomo-appconfig-$(date +%F).tar.gz
tar -C ~/selfhost/matomo -czf backups/matomo-compose-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: three files, none empty, all three sizes printed.

All three sit on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, copy all three there with `cp`, and have them confirm the filenames.
With no such destination, say plainly that this install has no backup.

To restore: untar the compose archive into ~/selfhost/matomo first, so .env is back before
anything starts, because MariaDB takes its password from it the moment it initialises an empty
volume. Then `docker compose down -v`, the one place `-v` belongs because it drops the old
volumes deliberately, `docker compose up -d`, wait for 8119, then
`docker compose exec -T app tar -C /var/www/html -xzf - < backups/matomo-appconfig-DATE.tar.gz`
and `gunzip -c` on the `.sql.gz` piped into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`.
Reload http://localhost:8119 and sign in: that is the whole disaster plan.

## 9. Updating later

New versions are at https://github.com/matomo-org/matomo/releases. Take all three backups
first, then edit both image lines in ~/selfhost/matomo/compose.yml: `app` and `archive` share
an image.

```bash
cd ~/selfhost/matomo
docker compose pull
docker compose up -d
docker compose exec -T -u www-data app php /var/www/html/console core:update --no-interaction
```

`core:update` applies the schema change; Matomo does not migrate on boot. Re-run step 7's
checks before calling the update done.

## 10. What will probably go wrong

I rebooted this machine, opened the dashboard, and got a connection error that reads like a
lost database. It was not: Docker Desktop had not started with the session, so nothing was
listening on 8119 and nothing was being counted either. `restart: unless-stopped` acts only
once the daemon is up, so turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/matomo && docker compose up -d` before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8119 to 0.0.0.0. That puts a one-password install on every network they join.
- Do not configure SMTP, do not install Marketplace plugins, and do not sign up with MaxMind.
  Heatmaps and Funnels are paid licences, and Matomo downloads a free DB-IP city database from
  its own Geolocation screen if the user ever wants one.
