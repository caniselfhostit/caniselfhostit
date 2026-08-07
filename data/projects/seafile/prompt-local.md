You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Seafile Community Edition 13.0.25, with the MariaDB and Redis it needs, under
~/selfhost/seafile, at http://localhost:8140.

## 1. Preflight

Say this before step 2 runs; it decides whether they want this install. Seafile syncs one set of
files across every device a person owns, and here only this computer reaches the server: the client
on this machine syncs, the phone in their pocket does not, and a share link lands nowhere.

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
distribution ID and codename print next, for step 2. The three services need 2048 MB of RAM
available and 10 GB free on the home disk, upstream's floor for the community edition. Under
either, print both numbers and stop.

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
mkdir -p ~/selfhost/seafile/data ~/selfhost/seafile/backups
ls -la ~/selfhost/seafile
```

Assert: `data` and `backups` listed. The container runs as root and fills `data` with `conf`,
`seafile-data`, `seahub-data` and `logs` on first boot; on Linux those end up owned by root and are
read with `sudo`, while Docker Desktop maps them to the user's account. MariaDB is elsewhere: step 5
keeps it in a volume Docker manages.

## 4. Secrets

Five secrets, all generated here. Print none of them, and keep them out of your summary and every
log line. Hex, not base64: two ride inside database connection strings.

```bash
umask 077
cat > ~/selfhost/seafile/.env <<EOF
SEAFILE_SERVER_HOSTNAME=localhost:8140
INIT_SEAFILE_ADMIN_EMAIL=admin@seafile.local
TIME_ZONE=Etc/UTC
INIT_SEAFILE_MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
SEAFILE_MYSQL_DB_PASSWORD=$(openssl rand -hex 32)
JWT_PRIVATE_KEY=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
INIT_SEAFILE_ADMIN_PASSWORD=$(openssl rand -hex 24)
EOF
chmod 600 ~/selfhost/seafile/.env
umask 022
ls -l ~/selfhost/seafile/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so this runs the same on all three systems.
`admin@seafile.local` is the username the one account is created under, never a mail address, and
`JWT_PRIVATE_KEY` needs 32 characters upstream and gets 64. On Windows those mode bits are advisory:
NTFS does not enforce them, and the boundary is the account.

## 5. compose.yml

```bash
cat > ~/selfhost/seafile/compose.yml <<'EOF'
# Seafile Community Edition · the deterministic fallback for the local path.
# Authored by caniselfhostit from the upstream documentation, not copied:
#   docker install ..... https://manual.seafile.com/13.0/setup/setup_ce_by_docker/
#   variable reference . https://manual.seafile.com/13.0/config/env/
#
# Three services, all on loopback; upstream's deployment starts five, adding a
# TLS proxy and the SeaDoc editor. Nothing here is public, so ENABLE_SEADOC
# is false and the hostname is localhost:8140 over http. Paths are relative to
# ~/selfhost/seafile/ except the database, a named volume because MariaDB chowns
# its data directory to a uid Docker Desktop on Windows cannot grant on a bind
# mount. Digests read 2026-08-06, all multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:10.11.18@sha256:de61fed4a40d3842f3ee09944ba52792156cfd9adf489b2cc670fc6ded28df8d
    container_name: seafile-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - seafile-mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      start_period: 30s
      timeout: 5s
      retries: 10
    # No `ports:` anywhere below: 3306 and 6379 stay on the compose network.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: seafile-redis
    restart: unless-stopped
    # A password, which upstream leaves off; $$ defers expansion to the container.
    command:
      - /bin/sh
      - -c
      - exec redis-server --requirepass "$$REDIS_PASSWORD" --save "" --appendonly no
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}

  seafile:
    image: seafileltd/seafile-mc:13.0.25@sha256:90c1aaa08731116750cd7ce16cbc6afe0c26006433002d3c7215a5f4254ec244
    container_name: seafile
    restart: unless-stopped
    volumes:
      - ./data:/shared
    environment:
      SEAFILE_MYSQL_DB_HOST: db
      SEAFILE_MYSQL_DB_USER: seafile
      SEAFILE_MYSQL_DB_PASSWORD: ${SEAFILE_MYSQL_DB_PASSWORD}
      INIT_SEAFILE_MYSQL_ROOT_PASSWORD: ${INIT_SEAFILE_MYSQL_ROOT_PASSWORD}
      SEAFILE_MYSQL_DB_CCNET_DB_NAME: ccnet_db
      SEAFILE_MYSQL_DB_SEAFILE_DB_NAME: seafile_db
      SEAFILE_MYSQL_DB_SEAHUB_DB_NAME: seahub_db
      CACHE_PROVIDER: redis
      REDIS_HOST: redis
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      JWT_PRIVATE_KEY: ${JWT_PRIVATE_KEY}
      SEAFILE_SERVER_HOSTNAME: ${SEAFILE_SERVER_HOSTNAME}
      SEAFILE_SERVER_PROTOCOL: http
      TIME_ZONE: ${TIME_ZONE}
      # Read on the first start only, to create the one account there is.
      INIT_SEAFILE_ADMIN_EMAIL: ${INIT_SEAFILE_ADMIN_EMAIL}
      INIT_SEAFILE_ADMIN_PASSWORD: ${INIT_SEAFILE_ADMIN_PASSWORD}
      # Upstream's editor extension, which would need a container of its own.
      ENABLE_SEADOC: "false"
    ports:
      # Loopback only: no other device on the wifi reaches 8140.
      - "127.0.0.1:8140:80"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_started

volumes:
  seafile-mysql:
EOF
cd ~/selfhost/seafile && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context, so crypto in the page still works.
- No firewall rule. Nothing is published beyond loopback, so nothing to close.

8140 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone. Confirm:

```bash
grep -n '127.0.0.1' ~/selfhost/seafile/compose.yml
```

Assert: one line, `- "127.0.0.1:8140:80"`. Neither backing service publishes a port.

## 7. Start and verify

First boot initialises MariaDB, creates and migrates three databases and seeds the one account.
That takes minutes and prints nothing for long stretches.

```bash
cd ~/selfhost/seafile
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8140/api2/ping/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8140/api2/ping/
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8140/api2/auth/ping/
docker compose exec -T seafile printenv SEAFILE_VERSION SEAFILE_SERVER_HOSTNAME
curl -sSL http://localhost:8140/accounts/login/ | grep -o '<h1 class="login-panel-hd">[^<]*</h1>'
```

Assert all five and print what you received. The loop ends on `200`. The ping prints `"pong"`.
`/api2/auth/ping/` prints `401`, the security assert here: the API is up and refusing a request with
no token. `printenv` prints `13.0.25` then `localhost:8140`. The last prints
`<h1 class="login-panel-hd">Log In</h1>`.

If any of the five misses, stop, run `docker compose logs --tail 60 seafile` and
`docker compose logs --tail 20 db`, and name the likely cause: a database that never reports healthy
points at step 4, where an empty password leaves MariaDB refusing to start. On
`port is already allocated`, find what holds 8140 (`lsof -nP -iTCP:8140 -sTCP:LISTEN`, or
`netstat -ano | findstr :8140`) and stop until it is freed. A running container is not success.

Nobody can sign up: upstream ships `ENABLE_SIGNUP` off, so it is the only way in.

STOP: tell the user to read their password with
`grep INIT_SEAFILE_ADMIN_PASSWORD ~/selfhost/seafile/.env`, put it in their password manager, open
http://localhost:8140, sign in as `admin@seafile.local`, create a library and upload one file, and
wait. Do not continue until they confirm the file is listed: the web interface loads fine even when
the file server behind /seafhttp does not.

## 8. First backup and restore

Two artifacts: a dump of the databases, and an archive of the blocks plus the files that rebuild
the service.

```bash
cd ~/selfhost/seafile
docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb-dump -uroot --opt --all-databases' | gzip > ~/selfhost/seafile/backups/seafile-db-$(date +%F).sql.gz
tar -C ~/selfhost/seafile -czf ~/selfhost/seafile/backups/seafile-files-$(date +%F).tar.gz data compose.yml .env
ls -lh ~/selfhost/seafile/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, and the
password is expanded inside the container. On Linux the container wrote `data` as root, so if `tar`
prints `Permission denied`, run that line again with `sudo`. `--all-databases` carries the `seafile`
MySQL user and its grants, without which a restore gives a database Seafile cannot log in to.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB stick,
and copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: they confirm
both filenames are there, or say plainly there is no backup.

To restore: untar the files archive into ~/selfhost/seafile first, so compose.yml and .env are back
before any container starts, then `docker compose down -v`, the one place `-v` belongs because it
drops the old database volume, `docker compose up -d db`, wait a minute for healthy, pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T db sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; exec mariadb -uroot'`,
`docker compose restart db`, then `docker compose up -d`. What matters at 2am: the blocks live under
`data/seafile/seafile-data` and their names in the database, so one without the other is useless.

## 9. Updating later

Image tags are listed at https://hub.docker.com/r/seafileltd/seafile-mc/tags. Back up first, then
edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/seafile
docker compose pull
docker compose up -d
docker compose logs --tail 40 seafile
```

The schema upgrade runs on the way up and takes minutes. Watch it, then re-run step 7.

## 10. What will probably go wrong

I rebooted, opened http://localhost:8140 out of habit, and got a connection refused that read like a
lost library. It was not: Docker Desktop had not started with the session, so nothing was listening
on 8140 and every file was fine and unreachable at once. `restart: unless-stopped` acts only once
the Docker daemon is up. Turn on its start-at-login setting, and after a reboot run
`cd ~/selfhost/seafile && docker compose up -d` and give it a minute.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `SEAFILE_SERVER_HOSTNAME` to this machine's LAN address and do not rebind 8140 to
  0.0.0.0 so a phone can reach it. That puts a file server holding everything on every network
  they join.
- Do not add the SeaDoc editor, the notification server or SMTP. Each is another container or
  integration, and this prompt installs the file server they plug into.
