You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install LimeSurvey 7.0.7, with the MariaDB it stores surveys and responses in, under
~/selfhost/limesurvey, answering at http://localhost:8130.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this. Every survey link this
makes begins with http://localhost:8130, which means "this computer" wherever it is
read, so one sent to a colleague or opened on the user's own phone resolves to nothing. They get
LimeSurvey's question logic and a private place to build questionnaires, not a survey anyone
else can answer.

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
distribution ID prints next, for step 2. LimeSurvey plus MariaDB needs 1024 MB of RAM available
and 5 GB free on the home disk, and both images publish amd64 and arm64. If either is under its
floor, print both numbers and stop.

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
mkdir -p ~/selfhost/limesurvey/backups
ls -la ~/selfhost/limesurvey
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: surveys are rows
in MariaDB, uploads live in a directory the image fills, and step 5 keeps both in volumes.

## 4. Secrets

Five secrets, all generated here: the database and MariaDB root passwords, the administrator's
password, and the two encryption values LimeSurvey uses for participant records. Print none, and
keep them out of your summary and every log.

```bash
umask 077
cat > ~/selfhost/limesurvey/.env <<EOF
HOST_INFO=http://localhost:8130
ADMIN_EMAIL=admin@localhost
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
ENCRYPT_NONCE=$(openssl rand -hex 24)
ENCRYPT_SECRET_BOX_KEY=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/limesurvey/.env
umask 022
ls -l ~/selfhost/limesurvey/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same on all three
systems. Those 24 and 32 hex bytes are the lengths LimeSurvey's own key generator produces;
change either later and encrypted records stop decrypting for good. On Windows the mode bits are
advisory and the user's own account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/limesurvey/compose.yml <<'EOF'
# LimeSurvey · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   config reference . https://www.limesurvey.org/manual/Optional_settings
#   image repo ....... https://github.com/martialblog/docker-limesurvey/tree/7.0.7-260729
#
# LimeSurvey publishes no Docker image; martialblog/limesurvey is a community
# image, MIT, whose Dockerfile fetches the official 7.0.7+260729 tarball and
# checks its sha256. Both mounts are named volumes: MariaDB chowns its data dir
# to its own uid, which Docker Desktop cannot grant on a Windows home-directory
# bind mount, and `upload` ships with base content a bind mount would hide.
# ${...} comes from ./.env, mode 600. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: limesurvey-db
    restart: unless-stopped
    environment:
      MARIADB_DATABASE: limesurvey
      MARIADB_USER: limesurvey
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - limesurvey-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  app:
    image: martialblog/limesurvey:7.0.7-260729-apache@sha256:556d09839640f4702ee5ef6618a426c68f0688ded967b2805a0bd903a241f051
    container_name: limesurvey-app
    restart: unless-stopped
    environment:
      DB_TYPE: mysql
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: limesurvey
      DB_USERNAME: limesurvey
      DB_PASSWORD: ${DB_PASSWORD}
      # Upstream's default engine; InnoDB caps a survey row near 8 KB.
      DB_MYSQL_ENGINE: MyISAM
      # The entrypoint exits without ADMIN_PASSWORD; these four seed it.
      ADMIN_USER: admin
      ADMIN_NAME: Site administrator
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      # Nothing terminates TLS here, so these links say http.
      HOST_INFO: ${HOST_INFO}
      # Written to config/security.php each start; changing either loses data.
      ENCRYPT_NONCE: ${ENCRYPT_NONCE}
      ENCRYPT_SECRET_BOX_KEY: ${ENCRYPT_SECRET_BOX_KEY}
    volumes:
      - limesurvey-upload:/var/www/html/upload
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://127.0.0.1:8080/index.php/admin/authentication/sa/login || exit 1"]
      start_period: 30s
      interval: 15s
      retries: 20
    ports:
      # Loopback only. The container listens on 8080, as www-data.
      - "127.0.0.1:8130:8080"
    depends_on:
      db:
        condition: service_healthy

volumes:
  limesurvey-db:
  limesurvey-upload:
EOF
cd ~/selfhost/limesurvey && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one port, two named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no
hostname to resolve. A certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway, so pages needing crypto still work. Nothing is published beyond loopback, so no port needs closing.

8130 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. That is the point of this path, not a defect in it.

```bash
grep -n '127.0.0.1' ~/selfhost/limesurvey/compose.yml
```

Assert: two lines, the container's healthcheck and `- "127.0.0.1:8130:8080"`. MariaDB publishes
no host port, so 3306 cannot appear.

## 7. Start and verify

On the first start the entrypoint waits for MariaDB, writes LimeSurvey's config, then runs the
console installer. Read step 10 before interpreting that log.

```bash
cd ~/selfhost/limesurvey
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8130/index.php/admin/authentication/sa/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8130/index.php/admin/authentication/sa/login | grep -c 'x-test id="action::login"'
curl -sS http://localhost:8130/index.php/installer | grep -c 'Installation has been done already'
docker compose exec -T db sh -c 'exec mariadb -N -B -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select count(*) from lime_users" "$MARIADB_DATABASE"'
```

Assert all four, printing what you received for each: the loop ends on `200`; the second prints
`1`, the marker LimeSurvey's test suite looks for to confirm the login page rendered, so PHP
reached the database; the third prints `1`, the security assert here, because a config file
exists and the installer now refuses whoever opens that address; the fourth prints `1`, the one
administrator the console installer made. If any misses, stop, run
`docker compose logs --tail 60 app` and `docker compose logs --tail 20 db`, and name the cause:
a database that never reports healthy points at step 4; `port is already allocated` means
something else holds 8130. A running container is not success.

The first screen at http://localhost:8130/index.php/admin shows the heading `Administration`
above the words `Log in`, with a username and a password field.

STOP: tell the user to read their administrator password with
`grep ADMIN_PASSWORD ~/selfhost/limesurvey/.env`, put it in their password manager, sign in at
http://localhost:8130/index.php/admin as the user `admin`, and wait. Do not continue until they
confirm.

## 8. First backup and restore

Three artifacts: a dump of every survey, question and response, an archive of themes, plugins
and uploads, and a config archive with the encryption keys the other two need.

```bash
cd ~/selfhost/limesurvey
docker compose exec -T db sh -c 'exec mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/limesurvey/backups/limesurvey-db-$(date +%F).sql.gz
docker compose exec -T app tar -C /var/www/html -czf - upload > ~/selfhost/limesurvey/backups/limesurvey-upload-$(date +%F).tar.gz
tar -C ~/selfhost/limesurvey -czf ~/selfhost/limesurvey/backups/limesurvey-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/limesurvey/backups/
```

Assert: all three exist and are non-empty, all three sizes printed. The dump read-locks each
table as it reads it: the survey tables are MyISAM, with no transaction to snapshot.

All three sit on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination that leaves this computer, a sync
folder or a USB stick, and copy all three there with `cp`. Assert: the user confirms all three
are listed there, or say plainly that this install has no backup.

To restore, untar the config archive into ~/selfhost/limesurvey first, so .env is back before
any container starts: MariaDB reads its password from it the moment it initialises an empty
volume, and its encryption values are the only way the restored data decrypts. Then
`docker compose down -v`, the one place `-v` belongs, `docker compose up -d db`, wait 30 seconds
for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d`, then the uploads with
`docker compose exec -T app tar -C /var/www/html -xzf - < backups/limesurvey-upload-<date>.tar.gz`.
Sign in once and open a survey. That is the whole disaster plan.

## 9. Updating later

Versions are listed at https://github.com/LimeSurvey/LimeSurvey/tags and the image tags at
https://github.com/martialblog/docker-limesurvey/tags. Take all three backups first, then edit
the app image line in ~/selfhost/limesurvey/compose.yml:

```bash
cd ~/selfhost/limesurvey
docker compose pull
docker compose up -d
docker compose logs --tail 40 app
```

The entrypoint runs `console.php updatedb` on every start, so a version bump migrates the schema
itself. Watch that log, then re-run step 7's four checks.

## 10. What will probably go wrong

I set a survey live on a Friday, closed the laptop, and found nothing waiting on Monday. Nothing
was broken: the machine was asleep, so 8130 answered nobody and everyone who opened the link got
a connection error instead of question one. `restart: unless-stopped` acts only once the Docker
daemon is up, and the daemon is up only while the computer is. Turn on Docker Desktop's
start-at-login setting, and treat this as a place to build surveys, not to leave one collecting.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `HOST_INFO` to this machine's LAN address and do not rebind 8130 to 0.0.0.0 so
  a phone can reach it. That puts an admin login on every network the user joins.
- Do not configure SMTP. Anonymous link surveys are the whole product without it.
- Do not use ComfortUpdate or the in-app updater. This container is pinned by digest.
