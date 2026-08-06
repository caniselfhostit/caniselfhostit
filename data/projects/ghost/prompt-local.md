You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Ghost 6.56.0, with the MySQL 8 it stores posts in, under ~/selfhost/ghost, answering at
http://localhost:8100.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Ghost is publishing software, and this copy publishes to an address only this computer can
open, so no reader, phone or colleague sees a word of it. They get the editor and the archive
on their own disk, not an audience.

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
distribution ID and codename print next, for step 2. Ghost plus MySQL 8 needs 2048 MB of RAM
available and 10 GB free on the home disk, and both images publish amd64 and arm64. On macOS
and Windows that figure is the host's, and Docker Desktop takes its allocation out of it. If
available RAM is under 2048 MB or free disk is under 10 GB, print both and stop.

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
mkdir -p ~/selfhost/ghost/content ~/selfhost/ghost/backups
ls -la ~/selfhost/ghost
```

Assert: `ls -la` shows `content` and `backups`, both owned by the user. Images, themes and
uploads land in `content`, a normal folder they can open in Finder or Explorer. Posts are rows
in MySQL, which step 5 keeps in a Docker-managed volume, so no ownership fix runs here.

## 4. Secrets

Two secrets: the MySQL root password and the `ghost` database user's password. Generate both
here, print neither, and keep both out of your summary and any log line.

```bash
umask 077
cat > ~/selfhost/ghost/.env <<EOF
GHOST_URL=http://localhost:8100
MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
GHOST_DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/ghost/.env
umask 022
ls -l ~/selfhost/ghost/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. Compose reads this file for both services, but only from
~/selfhost/ghost, so every docker command below starts with a `cd`. Neither value is a browser
login: the writing account is created in step 7. On Windows those mode bits are advisory, NTFS
does not enforce them, and the boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/ghost/compose.yml <<'EOF'
# Ghost · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://docs.ghost.org/install/docker/
#   image reference .... https://hub.docker.com/_/ghost
#   config reference ... https://docs.ghost.org/config/
#   supported databases  https://docs.ghost.org/faq/supported-databases/
#   mysql image ........ https://hub.docker.com/_/mysql
#
# Two services on your own computer, every path relative to ~/selfhost/ghost/ so
# one file works on macOS, Linux and Windows. SQLite is not an option: upstream
# states MySQL 8 is the only database it supports in production. MySQL's data
# directory is a named volume because the image chowns it to its own uid, which
# a home-directory bind mount cannot allow on Windows; Ghost's content stays a
# bind mount so images and themes show up in Finder or Explorer. Secrets come
# from ./.env, read when Compose runs from this folder. `url` is
# http://localhost:8100, so links resolve here and nowhere else. Digests read
# 2026-08-05; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  mysql:
    image: mysql:8.4.11@sha256:b3b90af2a6552ae30c266fdb7d5dd55f3afb72404bb78d37fe8a23eb857fd3fb
    container_name: ghost-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: ${GHOST_DB_PASSWORD}
    volumes:
      - ghost-mysql-data:/var/lib/mysql
    healthcheck:
      # `$$` sends a literal dollar to the container instead of interpolating.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -u root -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      retries: 30
      start_period: 60s
    # No `ports:`: 3306 is reachable only from the other container.

  ghost:
    image: ghost:6.56.0-alpine@sha256:57cd95050d3ca05a098c9ae1275c8d62ace1c844aa653494204d1c0e77c0900a
    container_name: ghost
    restart: unless-stopped
    environment:
      NODE_ENV: production
      url: ${GHOST_URL}
      # Two underscores separate nested config levels. Documented mapping.
      database__client: mysql
      database__connection__host: mysql
      database__connection__user: ghost
      database__connection__password: ${GHOST_DB_PASSWORD}
      database__connection__database: ghost
    volumes:
      # Posts live in MySQL. Images, themes and uploads live here.
      - ./content:/var/lib/ghost/content
    ports:
      # Loopback only: no other device on the wifi can reach 8100.
      - "127.0.0.1:8100:2368"
    depends_on:
      mysql:
        condition: service_healthy

volumes:
  ghost-mysql-data:
EOF
cd ~/selfhost/ghost && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK` and nothing else.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the editor's crypto works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8100 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, not anyone on the internet. For publishing software that is the shape of the trade, and
the point of this path rather than a defect. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/ghost/compose.yml
```

Assert: two lines, the MySQL healthcheck host and `- "127.0.0.1:8100:2368"`. MySQL publishes
no host port, so 3306 cannot appear.

## 7. Start and verify

Ghost runs its own migrations on first boot, which takes longer than the container takes to
appear.

```bash
cd ~/selfhost/ghost
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8100/ghost/api/admin/authentication/setup); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8100/ghost/api/admin/authentication/setup
```

Assert both, and print what you received. The loop ends printing `200`. The second command
prints exactly `{"setup":[{"status":false}]}`, upstream's way of saying the site exists and has
no owner yet. If either misses, stop, run `docker compose logs --tail 40 ghost`, and name the
likely cause: a MySQL that never reports healthy points at step 4, where an empty
`MYSQL_ROOT_PASSWORD` leaves it refusing to start, and a ghost log still in migrations wants
more time. If `port is already allocated` came back, find what holds 8100
(`lsof -nP -iTCP:8100 -sTCP:LISTEN`, or `netstat -ano | findstr :8100` on Windows) and stop
until the user frees it: 8100 is inside `url` and every link.
A running container is not success.

STOP: tell the user to open http://localhost:8100/ghost/ and create their account, and wait.
Do not continue until they confirm. The first screen carries the heading `Welcome to Ghost.`
above a form asking for a site title, full name, email address and a password of at least 10
characters. The email address is only a login here; the password goes in their password manager
first.

Once they confirm, prove the door is shut:

```bash
curl -sS http://localhost:8100/ghost/api/admin/authentication/setup
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8100/
```

Assert: the first prints exactly `{"setup":[{"status":true}]}` and the second prints `200`.
Both must pass before you report success.

## 8. First backup and restore

Two artifacts: a database dump with the posts, pages, tags and settings, and an archive with
the images, themes and the files that rebuild the service.

```bash
cd ~/selfhost/ghost
docker compose exec -T mysql sh -c 'exec mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers ghost' | gzip > ~/selfhost/ghost/backups/ghost-db-$(date +%F).sql.gz
tar -C ~/selfhost/ghost -czf ~/selfhost/ghost/backups/ghost-content-$(date +%F).tar.gz content compose.yml .env
ls -lh ~/selfhost/ghost/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. The password expands in a
shell inside the container, so it never reaches this machine's history; mysqldump prints one
warning about passwords on the command line, which is expected. Nothing goes offline:
`--single-transaction` snapshots a running InnoDB database consistently.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy both there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: they confirm both files are
there. If they have neither, say plainly there is no backup.

To restore, in this order. `cd ~/selfhost/ghost`, untar the archive there first so compose.yml
and .env are back before any container starts: MySQL reads its passwords from .env the moment
it initialises an empty volume, and a missing .env means a blank password and a database that
will not start. Then `docker compose down -v`, the one place `-v` belongs,
`docker compose up -d mysql`, wait a minute for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T mysql sh -c 'exec mysql -u root -p"$MYSQL_ROOT_PASSWORD" ghost'`, then
`docker compose up -d`. Load http://localhost:8100/ and check a post is there.

## 9. Updating later

New versions are at https://github.com/TryGhost/Ghost/releases and the digest is on
https://hub.docker.com/_/ghost. Take both backups first, then edit the image line in
~/selfhost/ghost/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/ghost
docker compose pull
docker compose up -d
docker compose logs --tail 30 ghost
```

Watch that log until it settles, then re-run step 7's setup check. Reach the last release of a
major version before crossing to the next: upstream says skipping ahead causes errors.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8100 to finish a draft, and got a connection
refused that reads like the whole site is gone. It was not: Docker Desktop had not started with
the session, so nothing was listening on 8100, and `restart: unless-stopped` acts only once the
Docker daemon is up. Turn on Docker Desktop's start-at-login setting, then after a reboot run
`cd ~/selfhost/ghost && docker compose up -d` and give MySQL its minute.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `url` to this machine's LAN address and do not rebind 8100 to 0.0.0.0 so a
  phone can reach it. That puts an admin panel on every network the user joins.
- Do not configure SMTP, and do not enable the analytics or ActivityPub profiles from Ghost's
  own compose repository. Each adds an outside account, and a newsletter with no public signup
  address has nobody to send to.
- Do not run Ghost-CLI commands inside the container. The official image documents that most of
  them are not designed to work there.
