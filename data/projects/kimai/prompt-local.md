You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Kimai 2.63.0, with the MySQL it keeps every timesheet in, under ~/selfhost/kimai,
answering at http://localhost:8126.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Kimai answers at http://localhost:8126 and nowhere else: not on their phone, not across the
room, not for a colleague billing the same job. A timer they cannot start from where they work
is one they forget, and forgotten hours go uninvoiced.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. Kimai plus MySQL needs 2048 MB of RAM
available and 10 GB free on the home disk; both images publish amd64 and arm64. On macOS and
Windows that memory figure is the host's, out of which Docker Desktop takes its own. If either
floor is missed, print both numbers and stop.

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
mkdir -p ~/selfhost/kimai/backups
ls -la ~/selfhost/kimai
```

Assert: `ls -la` shows `backups`, owned by the user. There is no data folder: both images chown
their data directory to a uid they pick, which a home bind mount cannot grant on Windows, so
step 5 uses Docker volumes.

## 4. Secrets

Four secrets, all generated here: the MySQL root password, the `kimai` user's database password,
`APP_SECRET`, and the one the container puts on the first admin account. Print none of them and
keep them out of your summary and every log line. Hex, not base64: the start-up script
splits `DATABASE_URL` on `/`, `:` and `@`, so any of those, or a `%`, breaks its wait loop.

```bash
umask 077
cat > ~/selfhost/kimai/.env <<EOF
ADMIN_EMAIL=admin@localhost
DB_ROOT_PASSWORD=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
APP_SECRET=$(openssl rand -hex 32)
ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/kimai/.env
umask 022
ls -l ~/selfhost/kimai/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these run the same on
all three systems. Compose reads it for the `${...}` substitutions in compose.yml, so it is
never mounted, and the address is only a label on an account that signs in as `admin`. On
Windows those mode bits are advisory: NTFS does not enforce them and the user's own account is
the boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/kimai/compose.yml <<'EOF'
# Kimai · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker compose ... https://www.kimai.org/documentation/docker-compose.html
#   docker image ..... https://www.kimai.org/documentation/docker.html
#   backups .......... https://www.kimai.org/documentation/backups.html
#
# Two services, run from ~/selfhost/kimai/. Both data directories are named
# volumes, not bind mounts: MySQL chowns /var/lib/mysql and Kimai chowns
# /opt/kimai/var, each to a uid it picks, which a home bind mount cannot grant
# on Windows. Digests read 2026-08-06; both images have arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  sqldb:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: kimai-db
    restart: unless-stopped
    command: --default-storage-engine innodb
    environment:
      MYSQL_DATABASE: kimai
      MYSQL_USER: kimai
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
    volumes:
      - kimai-mysqldata:/var/lib/mysql
    healthcheck:
      # Runs in the container, where that value already is an env var.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u kimai -p$$MYSQL_PASSWORD --silent"]
      start_period: 30s
      interval: 10s
      retries: 20
    # No `ports:` at all: 3306 is reachable only from the kimai container.

  kimai:
    image: kimai/kimai2:2.63.0@sha256:c0d55027c384b5f4e612dfeb326fdcff1d700dc469f85961b365eeb1c353119b
    container_name: kimai
    restart: unless-stopped
    environment:
      DATABASE_URL: "mysql://kimai:${DB_PASSWORD}@sqldb/kimai?charset=utf8mb4&serverVersion=8.4.0"
      APP_SECRET: ${APP_SECRET}
      # A regex Symfony matches the Host header against.
      TRUSTED_HOSTS: localhost|127.0.0.1
      # Created while ADMINPASS is set; step 7 drops that line from .env.
      ADMINMAIL: ${ADMIN_EMAIL}
      ADMINPASS: ${ADMIN_PASSWORD:-}
      memory_limit: 512M
    volumes:
      - kimai-vardata:/opt/kimai/var
    ports:
      # Loopback only: no device on the wifi can reach 8126.
      - "127.0.0.1:8126:8001"
    depends_on:
      sqldb:
        condition: service_healthy

volumes:
  kimai-mysqldata:
  kimai-vardata:
EOF
cd ~/selfhost/kimai && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one port, two volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8126 is bound to 127.0.0.1: not the phone, not a laptop on the wifi, nobody outside. Confirm:

```bash
grep -n '127.0.0.1:8126' ~/selfhost/kimai/compose.yml
```

Assert: one line, `- "127.0.0.1:8126:8001"`. MySQL publishes no host port.

## 7. Start and verify

MySQL initialises, Kimai's start-up script waits for it, builds the schema and creates an
account named `admin` with the password from step 4. First boot takes two or three minutes.

```bash
cd ~/selfhost/kimai
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8126/en/login); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8126/en/login | grep -o '<title>[^<]*</title>'
docker compose exec -T kimai /opt/kimai/bin/console kimai:user:list
```

Assert all three and print what you got: the loop ends on `200`; the second prints
`<title>Kimai</title>`; the third prints a one-row table with `Username` `admin`, `Roles`
including `ROLE_SUPER_ADMIN` and `Active` `Yes`. On any miss, stop, run
`docker compose logs --tail 40 kimai`, and name the cause: an empty user table means the
container never saw `ADMIN_PASSWORD`; `Wait for database connection` after five minutes means
MySQL never came up; `port is already allocated` means something else holds 8126
(`lsof -nP -iTCP:8126 -sTCP:LISTEN`, or `netstat -ano | findstr :8126`). A running container is
not success.

The first screen at http://localhost:8126 redirects to /en/login: the wordmark `Kimai` over the
line `Sign in to start your session`, a `Username` box, a `Password` box and a `Sign In` button.

STOP: tell the user to read the password with `grep ADMIN_PASSWORD ~/selfhost/kimai/.env`, put
it in their password manager, sign in as `admin`, and confirm the dashboard loads. Wait. Do not
continue until they confirm: the next block deletes this machine's copy.

Now close the bootstrap out. The start-up script runs under `bash -x`, so the account-creation
command, password included, was traced into the container log on first boot, and repeats on
every start while `ADMINPASS` is set:

```bash
cd ~/selfhost/kimai
(umask 077; grep -v '^ADMIN_PASS' .env > .env.new) && mv .env.new .env && chmod 600 .env
docker compose up -d --force-recreate kimai
sleep 60
docker compose logs kimai | grep -c 'kimai:user:create' || true
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8126/en/login
```

Assert both: the count prints `0` and the status prints `200`. That `0` is the security assert
here: the old container was replaced and its log file went with it, and the deleted line stops
the script recreating the account on every start. A count above `0` means the edit did not take,
so check `grep -c '^ADMIN_PASS' .env` and run it again. If the password is lost, recovery is
`docker compose exec -it kimai /opt/kimai/bin/console kimai:user:password admin`.

## 8. First backup and restore

Two artifacts. The database is the system of record: customers, projects, timesheets, rates and
invoices. The config archive holds the two files that rebuild it.

```bash
cd ~/selfhost/kimai
docker compose exec -T sqldb sh -c 'mysqldump --single-transaction --no-tablespaces -u kimai -p"$MYSQL_PASSWORD" kimai' | gzip > backups/kimai-db-$(date +%F).sql.gz
tar -C ~/selfhost/kimai -czf backups/kimai-config-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: both exist and neither is empty. Print both sizes. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database consistently, `--no-tablespaces` is
there because the `kimai` user is not a superuser, and the password is read inside the database
container so it never reaches this computer's process list. Say this too: Kimai's `var` volume,
holding rendered exports and invoices, is not in the backup: it re-renders them from the rows
that are.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a sync folder
or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both names are there, or say there is no backup.

To restore, in this order. Untar the config archive into ~/selfhost/kimai first, so .env is back
before any container starts: MySQL reads its passwords from that file the moment it initialises
an empty volume, and a missing .env means a blank password and a database that never starts.
Then `docker compose down -v`, the one place `-v` belongs because it drops the old volumes on
purpose, then `docker compose up -d sqldb`, wait a minute, and run
`gunzip -c backups/kimai-db-<date>.sql.gz | docker compose exec -T sqldb sh -c 'mysql -u kimai -p"$MYSQL_PASSWORD" kimai'`,
then `docker compose up -d`. Sign in and check an entry is there. An hour billed and not
provable is an hour that does not get paid.

## 9. Updating later

New versions are listed at https://github.com/kimai/kimai/releases. Kimai ships one most months
and each migrates the database on the way up, so back up first, then edit the image line:

```bash
cd ~/selfhost/kimai
docker compose pull
docker compose up -d
docker compose logs --tail 30 kimai
```

Watch it until it settles, then re-run step 7's first two checks.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8126 to start a timer, and got a connection
refused that reads like a broken install. It was not: Docker Desktop had not started with the
session, so nothing was listening on 8126 and no hours were recorded until it did.
`restart: unless-stopped` acts only once the Docker daemon is up. Turn on its start-at-login
setting, and after a reboot run `cd ~/selfhost/kimai && docker compose up -d` first.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8126 to 0.0.0.0 so a phone can reach it. That puts a login form holding the
  user's billing rates on every network they join.
- Do not configure SMTP, enable LDAP or SAML, or install plugins from the Kimai store. Each
  needs something this install lacks, and a broken plugin takes the app down.
