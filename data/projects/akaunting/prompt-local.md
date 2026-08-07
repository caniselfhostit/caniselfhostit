You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Akaunting 3.1.21, with the MariaDB it keeps the books in, under ~/selfhost/akaunting,
answering at http://localhost:8151.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install.
Akaunting answers at http://localhost:8151 and nowhere else, so the client portal is a
page only this computer opens: an invoice reaches a customer as a PDF they send. Akaunting is
also source-available, not open source, and its licence grants free production use for up to
two users, one company and one thousand invoices.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print too, for step 2. This needs 2048 MB of RAM available and
10 GB free on the home disk, and both images publish amd64 and arm64. Under either floor, print
both numbers and stop.

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
mkdir -p ~/selfhost/akaunting/backups
ls -la ~/selfhost/akaunting
```

Assert: `backups`, owned by the user. There is no `data` folder: the books are rows in MariaDB,
the application lives in /var/www/html, and step 5 keeps both in Docker-managed volumes, so no
ownership fix is needed.

## 4. Secrets

Three secrets: the MariaDB password for the `akaunting` user, the MariaDB root password, and
the password the installer puts on the first account. Generate all three here, print none, and
keep them out of your summary and every log.

```bash
umask 077
cat > ~/selfhost/akaunting/.env <<EOF
APP_URL=http://localhost:8151
LOCALE=en-US
COMPANY_NAME=My Company
COMPANY_EMAIL=owner@example.com
ADMIN_EMAIL=owner@example.com
DB_PASSWORD=$(openssl rand -hex 32)
MARIADB_ROOT_PASSWORD=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -base64 24)
AKAUNTING_SETUP=true
EOF
chmod 600 ~/selfhost/akaunting/.env
umask 022
ls -l ~/selfhost/akaunting/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same everywhere. The
account signs in as `owner@example.com`, an address that does not have to exist
because nothing here sends mail. On Windows those mode bits are advisory: NTFS does not enforce
them, and the user's account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/akaunting/compose.yml <<'EOF'
# Akaunting · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   image README ... https://github.com/akaunting/docker/blob/master/README.md
#   entrypoint ..... https://github.com/akaunting/docker/blob/master/files/akaunting.sh
#   variables ...... https://github.com/akaunting/docker/blob/master/env/run.env.example
#
# Two services, run from ~/selfhost/akaunting/. Both data directories are named
# volumes rather than relative binds: MariaDB chowns /var/lib/mysql and the
# entrypoint chowns /var/www/html, and a home bind mount cannot grant either on
# Windows. 3.1.21 is the newest tag akaunting/docker has published, and 3.2.1
# has no image behind it. Digests read 2026-08-06, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:11.8.8@sha256:d9f7eb2637296652f24b484afd5d246f759f49f5babcadc6a9e344c9acb75fbf
    container_name: akaunting-db
    restart: unless-stopped
    # Upstream's install page asks for utf8mb4_general_ci.
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
    environment:
      MARIADB_DATABASE: akaunting
      MARIADB_USER: akaunting
      MARIADB_PASSWORD: ${DB_PASSWORD}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
      MARIADB_DISABLE_UPGRADE_BACKUP: "1"
    volumes:
      - akaunting-mariadb:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  akaunting:
    image: akaunting/akaunting:3.1.21@sha256:50940112be48a229a2f567dc50ace9886fe5b14e1fe33f0232e704d0fb96f29f
    container_name: akaunting
    restart: unless-stopped
    environment:
      # The <base href> on every page: this computer, port digits and all.
      APP_URL: ${APP_URL}
      LOCALE: ${LOCALE}
      DB_HOST: db
      DB_PORT: "3306"
      DB_NAME: akaunting
      DB_USERNAME: akaunting
      DB_PASSWORD: ${DB_PASSWORD}
      DB_PREFIX: ""
      COMPANY_NAME: ${COMPANY_NAME}
      COMPANY_EMAIL: ${COMPANY_EMAIL}
      ADMIN_EMAIL: ${ADMIN_EMAIL}
      # The installer runs while AKAUNTING_SETUP is set; step 7 deletes it.
      ADMIN_PASSWORD: ${ADMIN_PASSWORD:-}
      AKAUNTING_SETUP: ${AKAUNTING_SETUP:-}
    volumes:
      - akaunting-html:/var/www/html
    ports:
      # Loopback only: no other device on the wifi can reach 8151.
      - "127.0.0.1:8151:80"
    depends_on:
      db:
        condition: service_healthy

volumes:
  akaunting-mariadb:
  akaunting-html:
EOF
cd ~/selfhost/akaunting && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, two named volumes, and no
default credential: upstream's example ships a published database password and
`me@company.com`, replaced in step 4.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, no public name for
a certificate to attest, nothing published beyond loopback to close. Browsers treat
http://localhost as a secure context, so pages needing crypto still work.

8151 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone. For a set of books that is the point. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/akaunting/compose.yml
```

Assert: that prints `1`, the one published port `- "127.0.0.1:8151:80"`. MariaDB publishes no
host port.

## 7. Start and verify

MariaDB initialises, then the entrypoint runs `php artisan install`: it writes the
application's .env inside the volume with a fresh `APP_KEY`, builds the schema, and creates the
company and the account. Apache starts a minute or two later.

```bash
cd ~/selfhost/akaunting
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8151/auth/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8151/auth/login | grep -o 'Login to start your session'
docker compose logs akaunting | grep -c 'Creating admin'
```

Assert all three, printing each: the loop ends on `200`; then
`Login to start your session`; then `1`, the installer's own line for the account it made. On
any miss, stop, run `docker compose logs --tail 60 akaunting` and say which step is the likely
cause: `Unable to find database!` is step 4. A running container is not success.

The first screen at http://localhost:8151/ redirects to /auth/login and shows the Akaunting
logo over the line `Login to start your session`, an `Email` box, a `Password` box and a
`Login` button.

STOP: tell the user to read the password with `grep ADMIN_PASSWORD ~/selfhost/akaunting/.env`,
put it in their password manager, sign in at http://localhost:8151/auth/login as
`owner@example.com`, rename the company under Settings, confirm the dashboard loads, and wait.
Do not continue until they confirm. The next block deletes this machine's copy.

Close the bootstrap out:

```bash
cd ~/selfhost/akaunting
sed -i -e '/^ADMIN_PASSWORD/d' -e '/^AKAUNTING_SETUP/d' ~/selfhost/akaunting/.env
docker compose up -d --force-recreate akaunting
sleep 45
docker compose logs akaunting | grep -c 'Creating admin' || true
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8151/auth/login
```

Assert both: the count that read `1` now prints `0`, and the status prints `200`. That `0` is
the security assert here: the replaced container starts Apache without running the installer
again. There is no reset mail, so the password manager entry is the recovery plan.

## 8. First backup and restore

Three artifacts: the dump holds the books; the application archive holds the volume's .env,
whose `APP_KEY` decrypts what Laravel encrypted, plus attachments; the config archive holds the
two files that rebuild the service around them.

```bash
cd ~/selfhost/akaunting
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --no-tablespaces -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' | gzip > ~/selfhost/akaunting/backups/akaunting-db-$(date +%F).sql.gz
docker compose exec -T akaunting tar -C /var/www/html -czf - .env storage modules > ~/selfhost/akaunting/backups/akaunting-app-$(date +%F).tar.gz
tar -C ~/selfhost/akaunting -czf ~/selfhost/akaunting/backups/akaunting-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/akaunting/backups/
```

Assert: all three exist, all three are non-empty, and print all three sizes.
`--single-transaction` snapshots a running InnoDB database, so nothing goes offline.

All three sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Have the user `cp` all three somewhere that leaves this computer, a sync folder or a
USB stick, and confirm they are listed there; in Git Bash a Windows drive is `/d/Backups`. If
they cannot, this install has no backup, and say so plainly.

To restore: untar the config archive into ~/selfhost/akaunting first, so .env is back before
any container starts, because MariaDB reads its passwords from it as it initialises. Then
`docker compose down -v`, `docker compose up -d db`, wait 30 seconds, pipe `gunzip -c` on the
dump into
`docker compose exec -T db sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'`,
then `docker compose up -d akaunting` to refill the volume from the image,
`docker compose exec -T akaunting tar -C /var/www/html -xzf - < backups/akaunting-app-<date>.tar.gz`,
and `docker compose restart akaunting`. Sign in and check an invoice is there.

## 9. Updating later

Two things move separately. A newer image tag moves PHP and Apache, but the application lives
in the `akaunting-html` volume, which Docker filled once and will not refill, so back up first,
edit the image line to the new tag and digest, then run:

```bash
cd ~/selfhost/akaunting
docker compose pull
docker compose up -d
docker compose logs --tail 30 akaunting
```

Tags are at https://hub.docker.com/r/akaunting/akaunting/tags. Akaunting itself moves with the
updater upstream documents: `docker compose exec -T akaunting php artisan update:all`.

## 10. What will probably go wrong

I closed the lid, came back next morning, opened the bookmark and got a connection error
that read like the whole install had gone. It had not. Docker Desktop had not started with the
session, so nothing was listening on 8151, and `restart: unless-stopped` acts only once the
Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/akaunting && docker compose up -d` before concluding it is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP. Email Invoice then does nothing, and the user sends the PDF.
- Do not add a cron container or scheduler service. Nothing runs Laravel's scheduler here, so
  recurring invoices never fire.
- Do not enter an Akaunting API key or install app-store apps; those are purchases tied to an
  akaunting.com account.
