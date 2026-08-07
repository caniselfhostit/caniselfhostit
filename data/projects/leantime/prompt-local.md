You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Leantime 3.9.8, with the MySQL it keeps every project in, under ~/selfhost/leantime,
answering at http://localhost:8163.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Leantime answers at http://localhost:8163 and nowhere else. It is built for a team to share, and
here nobody can be invited: not a colleague, not a client, not their own phone. It is a planner
for one.

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
distribution ID and codename print next, for step 2. Leantime plus MySQL needs 2048 MB of RAM
available and 10 GB free on the home disk, and both images have amd64 and arm64. On macOS and
Windows that figure is the host's. If either floor is missed, print both and stop.

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
mkdir -p ~/selfhost/leantime/{backups,userfiles,public-userfiles}
if [ "$(uname -s)" = "Linux" ]; then sudo chown 1000:1000 ~/selfhost/leantime/{userfiles,public-userfiles}; fi
ls -la ~/selfhost/leantime
```

Assert: `ls -la` shows all three folders. The app image runs as `www-data`, uid 1000, and on
Linux can only write to a folder that uid owns, which the guarded line arranges; on macOS and
Windows it is a no-op, because Docker Desktop handles ownership. MySQL has no folder: step 5
keeps its data in a volume Docker manages.

## 4. Secrets

Three secrets, all generated here: the MySQL root password, the `leantime` user's database
password, and `LEAN_SESSION_PASSWORD`, which salts every session. Print none of them and keep
them out of your summary and every log line. Hex, not base64: Compose reads this file and treats
an unquoted `#` as a comment.

```bash
umask 077
cat > ~/selfhost/leantime/.env <<EOF
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
LEAN_SESSION_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/leantime/.env
umask 022
ls -l ~/selfhost/leantime/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these run the same on
all three systems, and Compose reads it here rather than mounting it. On Windows those mode bits
are advisory: NTFS does not enforce them, and the user's account is the boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/leantime/compose.yml <<'EOF'
# Leantime · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install .... https://docs.leantime.io/installation/docker
#   variable reference  https://github.com/Leantime/docker-leantime/blob/master/sample.env
#   backup & restore .. https://docs.leantime.io/installation/backup-restore
#
# Two services, run from ~/selfhost/leantime/. The userfiles folders are
# relative binds so uploads stay visible in Finder or Explorer; MySQL's is a
# named volume: that image chowns /var/lib/mysql itself. No plugin mount:
# upstream asks for one only if you install marketplace plugins, and this
# install does not. Digests read 2026-08-07; both images have arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  leantime_db:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: leantime-db
    restart: unless-stopped
    command: --character-set-server=UTF8MB4 --collation-server=UTF8MB4_unicode_ci
    environment:
      MYSQL_DATABASE: leantime
      MYSQL_USER: leantime
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - leantime-mysqldata:/var/lib/mysql
    healthcheck:
      # Runs in the container, where that value is already an env var.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u leantime -p$$MYSQL_PASSWORD --silent"]
      start_period: 30s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the other container.

  leantime:
    image: leantime/leantime:3.9.8@sha256:6150dd3e8a1e17f1ead8d462d31e26177fe906ce3602dbbbf6af5417ef809de3
    container_name: leantime
    restart: unless-stopped
    # Both come from upstream's compose file for this service.
    security_opt:
      - no-new-privileges:true
    cap_add:
      - CAP_CHOWN
      - CAP_SETGID
      - CAP_SETUID
    environment:
      LEAN_DB_HOST: leantime_db
      LEAN_DB_PORT: "3306"
      LEAN_DB_DATABASE: leantime
      LEAN_DB_USER: leantime
      LEAN_DB_PASSWORD: ${DB_PASSWORD}
      # Salts every session. Change it later and everyone is signed out.
      LEAN_SESSION_PASSWORD: ${LEAN_SESSION_PASSWORD}
      # Upstream needs this set for proxy installs; without it /install loops.
      LEAN_APP_URL: http://localhost:8163
      # false because this is http, not https.
      LEAN_SESSION_SECURE: "false"
      LEAN_DEFAULT_TIMEZONE: UTC
    volumes:
      - ./userfiles:/var/www/html/userfiles
      - ./public-userfiles:/var/www/html/public/userfiles
    ports:
      # Loopback only: no device on the wifi can reach 8163.
      - "127.0.0.1:8163:8080"
    depends_on:
      leantime_db:
        condition: service_healthy

volumes:
  leantime-mysqldata:
EOF
cd ~/selfhost/leantime && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, two binds, one volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision: no hostname to
resolve, nothing public to certify, nothing published past loopback to close. Browsers treat
http://localhost as a secure context, so crypto in the page works without TLS. 8163 is bound to
127.0.0.1: not the phone, not a laptop on the wifi, nobody outside. For a tool built to
be shared that is the trade, and it is the point of this path rather than a defect.

```bash
grep -c '"127.0.0.1:' ~/selfhost/leantime/compose.yml
```

Assert: that prints `1`, the single published port. MySQL publishes no host port, so 3306 cannot
appear. The health check names 127.0.0.1 too, but inside the container, hence the quoted form.

## 7. Start and verify

MySQL initialises first and the app container waits for it, so nothing answers on 8163 for a
minute. `/healthCheck.php` is served by nginx outside the application router.

```bash
cd ~/selfhost/leantime
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8163/healthCheck.php); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8163/healthCheck.php
curl -sS http://localhost:8163/install | grep -c 'This script will set up your database' || true
```

Assert all three and print what you got: the loop ends on `200`, the second prints `Ok` and
nothing else, the third prints `1`. On any miss, stop, run
`docker compose logs --tail 40 leantime` and `docker compose logs --tail 20 leantime_db`, and name
the cause: a refused connection that never clears means the database never reported healthy;
`port is already allocated` means something holds 8163, which `lsof -nP -iTCP:8163 -sTCP:LISTEN`
names. A running container is not success.

The first screen at http://localhost:8163 redirects to /install: the heading `Installation` over
the line `This script will set up your database and create an administrator account`, then boxes
for `Email`, `First name`, `Last name` and `Company Name`, and an `Install` button. No default
account exists.

STOP: tell the user to open http://localhost:8163/install, fill that form in, press `Install`,
then set a password on the `Setting Account Details` screen next. Upstream wants 8 characters
with an uppercase, a lowercase, a number and a symbol; nothing here can mail it back, so it goes
in their password manager. Wait. Do not continue until they confirm.

Then prove the installer closed behind them:

```bash
curl -sS http://localhost:8163/install | grep -c 'This script will set up your database' || true
curl -sSL http://localhost:8163/ | grep -c '<label for="password">Password</label>' || true
```

Assert both: the first prints `0`, the second `1`. That `0` is the security assert here: Leantime
stops serving the installer once the user table exists. The `1` is the login form at the root.

## 8. First backup and restore

Two artifacts. The database holds every project, task, goal, wiki page and comment; the archive
holds the uploads and the two files that rebuild it.

```bash
cd ~/selfhost/leantime
docker compose exec -T leantime_db sh -c 'mysqldump --single-transaction --no-tablespaces -u leantime -p"$MYSQL_PASSWORD" leantime' | gzip > backups/leantime-db-$(date +%F).sql.gz
tar -C ~/selfhost/leantime -czf backups/leantime-files-$(date +%F).tar.gz compose.yml .env userfiles public-userfiles
ls -lh backups/
```

Assert: both exist and neither is empty. Print both sizes. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database, `--no-tablespaces` is there because
the `leantime` user is not a superuser, and the password is read in the database container.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a sync folder or
a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both names are there, or say there is no backup.

To restore, in this order. Untar the archive into ~/selfhost/leantime first, so .env is back
before any container starts: MySQL reads its passwords from it when it initialises an empty
volume. Then `docker compose down -v`, the one place `-v` belongs, dropping the old volume on
purpose, then `docker compose up -d leantime_db`, wait a minute, then
`gunzip -c backups/leantime-db-<date>.sql.gz | docker compose exec -T leantime_db sh -c 'mysql -u leantime -p"$MYSQL_PASSWORD" leantime'`,
then `docker compose up -d`. Sign in and check a project is there. The dump is the whole plan;
`LEAN_SESSION_PASSWORD` is in .env alone.

## 9. Updating later

New versions are listed at https://github.com/Leantime/leantime/releases. Leantime ships several
in a busy month and each migrates its own schema, so back up both first, then edit the image
line:

```bash
cd ~/selfhost/leantime
docker compose pull
docker compose up -d
docker compose logs --tail 30 leantime
```

Watch it until it settles, then re-run step 7's first two checks. If a version wants a schema
change it serves `/install/update`; the user presses it once.

## 10. What will probably go wrong

8163 is not only a port here, it is written into `LEAN_APP_URL`, and I learned that the noisy way.
Something else already held 8163, so I moved the published port to 8164, the container came up
clean, and every request bounced back to http://localhost:8163 and died: Leantime builds its
redirects from the address it was given, not the one you ask on. If 8163 changes, change both
lines in compose.yml, the `ports:` entry and `LEAN_APP_URL`, then
`docker compose up -d --force-recreate`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8163 to 0.0.0.0 so a phone or colleague can reach it. That puts a login form
  holding the user's plans and client names on every network they join.
- Do not configure SMTP, enable LDAP or OIDC, or install marketplace plugins. Each needs
  something this install lacks, and no volume keeps a plugin across a restart.
