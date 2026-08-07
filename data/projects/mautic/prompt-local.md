You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Mautic 7.1.3, with its MariaDB and its cron container, under ~/selfhost/mautic,
answering at http://localhost:8161.

## 1. Preflight

Say this to the user before step 2, because it decides whether they want this install at all.
Mautic's Site URL here is http://localhost:8161, which means this computer wherever it is read,
so every link, unsubscribe address and tracking pixel Mautic writes into a campaign is dead for
whoever receives it. They get the whole machine to learn on, with their contacts and consent on
their own disk, not a sending platform.

Detect the OS and measure:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. Two PHP containers plus MariaDB need
2048 MB of RAM available and 10 GB free on the home disk; both images publish amd64 and arm64.
On macOS and Windows the figure is the host's, and Docker Desktop takes its allocation out of
it. Under either floor, print both numbers and stop.

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
mkdir -p ~/selfhost/mautic/config ~/selfhost/mautic/logs ~/selfhost/mautic/media/files ~/selfhost/mautic/media/images ~/selfhost/mautic/backups
ls -la ~/selfhost/mautic
```

Assert: five directories owned by the user. No ownership fix is needed anywhere: the image
starts as root and chowns those four mounts to www-data itself. The database gets no directory
here: step 5 keeps it in a Docker volume.

## 4. Secrets

Three: the `mautic` database password, the MariaDB root password, and the one for the
administrator account step 7 creates. Print none of them and keep all three out of your summary
and every log line.

```bash
umask 077
cat > ~/selfhost/mautic/.env <<EOF
MARIADB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
MAUTIC_ADMIN_PASSWORD=$(openssl rand -base64 24)
EOF
chmod 600 ~/selfhost/mautic/.env
umask 022
ls -l ~/selfhost/mautic/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these run the same everywhere. On Windows
the mode bits are advisory, because NTFS does not enforce them; the real boundary is the user's
Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/mautic/compose.yml <<'EOF'
# Mautic · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image README ....... https://github.com/mautic/docker-mautic
#   container roles .... https://github.com/mautic/docker-mautic/blob/main/common/docker-entrypoint.sh
#   cron jobs .......... https://docs.mautic.org/en/7.1/configuration/cron_jobs.html
#
# Three services, every path relative to ~/selfhost/mautic/ so one file works
# on macOS, Linux and Windows. The database is a named volume, not a bind
# mount, because MariaDB chowns its data directory to its own uid and a
# home-directory bind cannot allow that on Windows. Digests read 2026-08-06;
# amd64 and arm64 both published.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

x-mautic-env: &mautic-env
  MAUTIC_DB_HOST: db
  MAUTIC_DB_DATABASE: mautic
  MAUTIC_DB_USER: mautic
  MAUTIC_DB_PASSWORD: ${MARIADB_PASSWORD}
  PHP_INI_VALUE_MEMORY_LIMIT: 768M

x-mautic-volumes: &mautic-volumes
  - ./config:/var/www/html/config
  - ./logs:/var/www/html/var/logs
  - ./media/files:/var/www/html/docroot/media/files
  - ./media/images:/var/www/html/docroot/media/images

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
      - mautic-dbdata:/var/lib/mysql
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
      MAUTIC_ADMIN_PASSWORD: ${MAUTIC_ADMIN_PASSWORD}
    volumes: *mautic-volumes
    healthcheck:
      test: ["CMD-SHELL", "curl -sS -o /dev/null http://127.0.0.1/ || exit 1"]
      start_period: 30s
      interval: 10s
      retries: 30
    ports:
      # Loopback only: no other device on the wifi can reach 8161.
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

volumes:
  mautic-dbdata:
EOF
cd ~/selfhost/mautic && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one published port, one named volume. Without
`mautic_cron`, segments never refresh and campaign steps never fire.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. A certificate attests a public name and
nothing here has one; browsers treat http://localhost as a secure context anyway, so pages
needing crypto work. Nothing is published beyond loopback: 8161 binds to 127.0.0.1, this
computer only, not the user's phone, not a laptop on the same wifi, not anyone on the internet.
Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/mautic/compose.yml
```

Assert: `1`, the published port `- "127.0.0.1:8161:80"`. MariaDB publishes none, so 3306 cannot
appear.

## 7. Start and verify

The first start pulls about 1.5 GB. Mautic ships with no schema and no account; the install
line creates both, with `admin@example.com` as the address because nothing here can send to a
real one.

```bash
cd ~/selfhost/mautic
docker compose pull
docker compose up -d
for i in $(seq 1 40); do state=$(docker inspect -f '{{.State.Health.Status}}' mautic-web 2>/dev/null || echo none); echo "$i $state"; [ "$state" = healthy ] && break; sleep 10; done
docker compose exec -T -u www-data -w /var/www/html mautic_web sh -c 'php ./bin/console mautic:install http://localhost:8161 --admin_email admin@example.com --admin_password "$MAUTIC_ADMIN_PASSWORD" --force'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8161/s/login
curl -sS http://localhost:8161/s/login | grep -c 'Username or email'
docker compose exec -T mautic_cron crontab -l -u www-data | grep -c 'mautic:segments:update'
docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:segments:update --no-ansi && echo "console OK"
```

Assert, printing what you received for each: the loop ends on `healthy`, the install prints
`Install complete`, the curl prints `200`, the page grep prints `1`, the crontab grep prints
`1`, and the last line prints `console OK`, the command line reaching the database the
installer wrote to. If any miss, stop, run `docker compose logs --tail 40 mautic_web` and
`docker compose logs --tail 20 db`, and name the likely cause: a database that never reports
healthy is step 4, where an empty password leaves MariaDB refusing to start, and a crontab `0`
is a cron container still waiting on the install, so restart `mautic_cron`. On `port is already
allocated`, find what holds 8161 with `lsof -nP -iTCP:8161 -sTCP:LISTEN`, or
`netstat -ano | findstr :8161` on Windows, and stop until the user frees it: that port is in the
Site URL and in every link. A running container is not success.

The first screen at http://localhost:8161/s/login shows `Username or email` in the first field,
a `Password` field, a `Keep me logged in` box and a `Login` button.

STOP: tell the user to read the administrator password with
`grep MAUTIC_ADMIN_PASSWORD ~/selfhost/mautic/.env`, put it in their password manager, log in at
http://localhost:8161/s/login as `admin`, and wait. Do not continue until they confirm. Tell
them what stays broken meanwhile: the mailer ships pointed at `smtp://localhost:1025` and the
from-address at `email@yoursite.com`, so nothing leaves here until Settings -> Configuration ->
Email Settings names a relay and an address they own.

## 8. First backup and restore

Two artifacts: the database holds contacts, consent, segments and campaigns; the config archive
rebuilds the service around it.

```bash
cd ~/selfhost/mautic
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/mautic/backups/mautic-db-$(date +%F).sql.gz
tar -C ~/selfhost/mautic -czf ~/selfhost/mautic/backups/mautic-config-$(date +%F).tar.gz compose.yml .env config media
ls -lh ~/selfhost/mautic/backups/
```

Assert: both exist, both are non-empty, both sizes printed. Both carry live credentials, .env
the database's and local.php the relay's once it is set; tell the user that.

They also sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a folder their sync service
watches or a USB stick, and copy both there with `cp`; in Git Bash a Windows drive is written
`/d/Backups`. Assert: the user confirms both filenames are there. If they have neither, say
plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/mautic`, untar the config archive there first so
compose.yml and .env are back before any container starts, because MariaDB reads its password
from .env when it initialises an empty volume. Then `docker compose down -v`, the one
place `-v` belongs because it drops the old volume on purpose, `docker compose up -d db`, wait
40 seconds for healthy, then pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d` and re-run step 7's asserts.

## 9. Updating later

New versions are at https://github.com/mautic/mautic/releases. Back up first, then edit both
Mautic image lines in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/mautic
docker compose pull
docker compose up -d
docker compose logs --tail 40 mautic_web
```

The web container migrates its own database on the way up, so watch that log until it settles,
then re-run step 7's asserts.

## 10. What will probably go wrong

I scheduled a campaign for six in the morning, shut the laptop, and found nothing had happened.
Nothing was broken. A campaign step fires when `mautic:campaigns:trigger` runs in the cron
container, that container runs only while Docker Desktop runs, and Docker Desktop runs only
while the machine is awake. Mautic here does as much work as the computer is switched on for,
and after a reboot `restart: unless-stopped` waits for the daemon, so run
`cd ~/selfhost/mautic && docker compose up -d` first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change the Site URL to this machine's LAN address so a phone can reach it, and do not
  rebind 8161 to 0.0.0.0. That puts a marketing database with a login form on every network the
  user joins.
