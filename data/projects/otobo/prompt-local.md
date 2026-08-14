You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install OTOBO 11.0.17 under ~/selfhost/otobo, answering at http://localhost:8202.

## 1. Preflight

Say this before step 2, because it decides whether the user wants this install: a helpdesk
exists so other people can reach you, and this one answers at http://localhost:8202, this
computer and nowhere else.

Detect the OS and measure the machine:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the
distribution ID and codename print next, for step 2. If `uname -m` printed `arm64` or `aarch64`,
stop and say why: upstream publishes the OTOBO image for amd64 only, so an Apple Silicon Mac has
nothing to pull. This needs x86-64, 4096 MB of RAM available and 20 GB free on the home disk,
and Docker Desktop takes its share of both. Under either floor, print both numbers and stop.

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

Two directories. The OTOBO image runs as uid 1000 and copies its application tree into `otobo/`
on first start, so on Linux that directory belongs to 1000. The fence is a no-op on macOS and
Windows.

```bash
mkdir -p ~/selfhost/otobo/otobo ~/selfhost/otobo/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/otobo/otobo
fi
ls -la ~/selfhost/otobo
```

Assert: `ls -la` shows `otobo` and `backups`. The database is a named volume, not a folder
here, because that image chowns its own data directory. Step 8 dumps it.

## 4. Secrets

One secret, the MariaDB root password, generated here into a file only this account can read.
Do not print it and do not repeat it in your summary. Hex rather than base64: the user retypes
it into a browser form in step 7, and it ends up inside a `CREATE USER` statement.

```bash
umask 077
cat > ~/selfhost/otobo/.env <<EOF
OTOBO_DB_ROOT_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/otobo/.env
umask 022
ls -l ~/selfhost/otobo/.env
```

Assert: mode `-rw-------`; on Windows those bits are advisory and the real boundary is the
user's own account. They read it with `grep OTOBO_DB_ROOT_PASSWORD ~/selfhost/otobo/.env`, once,
in step 7.

## 5. compose.yml

```bash
cat > ~/selfhost/otobo/compose.yml <<'EOF'
# OTOBO · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a
# repository:
#   docker install ..... https://doc.otobo.org/manual/installation/11.0/en/content/installation/installation-docker.html
#   upstream compose ... https://github.com/RotherOSS/otobo-docker/blob/rel-11_0_17/docker-compose/otobo-base.yml
#
# Four services on the computer you are sitting at; `web` and `daemon` are one
# image dispatched on the command word, and no daemon means no SLA fires.
# Attachments live in the database. Redis is required under Docker (the
# image's Kernel/Config.pm points the cache at redis:6379); Elasticsearch is
# optional upstream and left out.
# ./otobo is a relative bind mount, written by uid 1000, hence step 3's
# Linux-only chown; the database is a named volume because the MariaDB image
# chowns its data directory itself. Digests read 2026-08-14; amd64 only.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: mariadb:12.3.2-noble@sha256:759869cb6f003234a95c6384cdee245b4bce7de26913fe607a8110362c0c007d
    container_name: otobo-db
    restart: unless-stopped
    command: --max-allowed-packet=136314880 --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-log-file-size=268435456
    environment:
      MARIADB_ROOT_PASSWORD: ${OTOBO_DB_ROOT_PASSWORD}
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - otobo-mariadb-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 30s
      interval: 10s
      retries: 30

  redis:
    image: redis:8.4.0-bookworm@sha256:c22af04bb576503bf16b3e34a1fd2fd82de0f765afd866d2e380145e0af30d78
    container_name: otobo-redis
    restart: unless-stopped
    user: redis:redis
    cap_drop:
      - ALL
    command: ["redis-server", "--save", ""]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 10

  web:
    image: rotheross/otobo:rel-11_0_17@sha256:381ec32cc5c53bd468af917a888b295497336a73cbd3e1657ce02e474eba383d
    container_name: otobo-web
    restart: unless-stopped
    cap_drop:
      - ALL
    command: web
    volumes:
      - ./otobo:/opt/otobo
    healthcheck:
      test: ["CMD-SHELL", "curl -sS -f http://localhost:5000/robots.txt >/dev/null"]
      start_period: 300s
      interval: 15s
      retries: 20
    ports:
      # Loopback only: no other device on the wifi reaches 8202.
      - "127.0.0.1:8202:5000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  daemon:
    image: rotheross/otobo:rel-11_0_17@sha256:381ec32cc5c53bd468af917a888b295497336a73cbd3e1657ce02e474eba383d
    container_name: otobo-daemon
    restart: unless-stopped
    cap_drop:
      - ALL
    command: daemon
    volumes:
      - ./otobo:/opt/otobo
    healthcheck:
      # Unhealthy until the installer finishes: it exits while SecureMode
      # is off, retried every two minutes.
      test: ["CMD-SHELL", "./bin/otobo.Daemon.pl status | grep -q 'Daemon running'"]
      start_period: 300s
      interval: 30s
      retries: 10
    depends_on:
      web:
        condition: service_started

volumes:
  otobo-mariadb-data:
EOF
cd ~/selfhost/otobo && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Four services, one port.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: a certificate attests a public name, and
nothing here has one. Confirm the binding:

```bash
grep -c '"127.0.0.1:' ~/selfhost/otobo/compose.yml
```

Assert: that prints `1`, the one published port `127.0.0.1:8202:5000`; the database and Redis
have no host port. No phone, no laptop on the wifi and nobody on the internet reaches this desk,
which for a helpdesk is the whole trade. Browsers treat http://localhost as a secure context, so
the login works without TLS; step 7 sets OTOBO's HTTP Type to `http` to match.

## 7. Start and verify

The first start looks broken and is not: the web container copies a gigabyte out of the image
into ~/selfhost/otobo/otobo before it listens. Use the loop.

```bash
cd ~/selfhost/otobo
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8202/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sSL http://localhost:8202/otobo/installer.pl | grep -c 'Welcome to OTOBO'
```

Assert both. The loop ends on `200`, and `/health` is a static file, so it proves Perl is
listening and nothing about the database. The grep prints above `0`. On a miss read
`docker compose logs --tail 40 web`, then `db`. If `port is already allocated` came back, find
what holds 8202 with `lsof -nP -iTCP:8202` and stop until it is free.

STOP: tell the user to open http://localhost:8202/otobo/installer.pl and work its four steps,
then wait. Do not continue until they confirm. The values not obvious on screen: `MySQL` and
`Create a new database for OTOBO`; User `root`, Host `db`, Database `otobo`, and in the blank
field the password from `grep OTOBO_DB_ROOT_PASSWORD ~/selfhost/otobo/.env`; keep the generated
database password; HTTP Type `http`, System FQDN `localhost`; `Skip this step` on the mail
screen. The last page prints `root@localhost` and a password, shown once.

Once they confirm, shut the last door and prove all of it. Upstream ships
`CustomerPanelCreateAccount` on, so the customer portal offers a `Request Account` form to
anyone reaching it, and with no mail here that account could never learn one.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8202/otobo/installer.pl
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8202/otobo/migration.pl
docker compose exec -T web bin/otobo.Console.pl Admin::Config::Update --setting-name CustomerPanelCreateAccount --value 0
docker compose restart web
sleep 45
curl -sSL http://localhost:8202/otobo/customer.pl | grep -c 'oooRegister'
docker compose ps --format '{{.Service}} {{.Health}}' | grep daemon
```

Assert, in order: `403`, `403`, `Done`, then `0`, and `healthy` within two minutes. SecureMode
is on, so the middleware now refuses installer.pl and migration.pl, the setup door and the OTRS
migration door. The `0` is the customer signup form gone; agents have no self-service door.
Unhealthy on the daemon means no escalation clock fires. All of these pass.

## 8. First backup and restore

Two artifacts. The database is every ticket, article and attachment, because upstream keeps
attachments in it. The archive beside it carries Kernel/Config.pm, with OTOBO's own database
password.

```bash
cd ~/selfhost/otobo
docker compose exec -T db sh -c 'exec mariadb-dump --single-transaction --max-allowed-packet=136314880 -u root -p"$MARIADB_ROOT_PASSWORD" otobo' | gzip > ~/selfhost/otobo/backups/otobo-db-$(date +%F).sql.gz
tar -czf ~/selfhost/otobo/backups/otobo-config-$(date +%F).tar.gz --exclude=var/tmp -C ~/selfhost/otobo compose.yml .env -C ~/selfhost/otobo/otobo Kernel/Config.pm var
ls -lh ~/selfhost/otobo/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops, because
`--single-transaction` snapshots InnoDB consistently.

That archive is on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask for a destination that leaves this computer, a sync folder or a USB stick, and
copy both there with `cp`. Assert: the user confirms both filenames are there.

To restore: `docker compose down -v`, untar the config archive into ~/selfhost/otobo,
`docker compose up -d db`, wait for healthy. Read the database user and password out of the
restored `otobo/Kernel/Config.pm`, recreate that database and user through
`docker compose exec db mariadb -u root -p` with `CHARACTER SET utf8mb4 COLLATE
utf8mb4_unicode_ci` and `ALL ON otobo.*`, then pipe the dump through `gunzip -c` into
`docker compose exec -T db mariadb -u root -p otobo` and `up -d`.

## 9. Updating later

Releases are git tags rather than GitHub releases, at https://github.com/RotherOSS/otobo/tags.
OTOBO writes version identity with underscores, so 11.0.17 is the tag `rel-11_0_17` and the
Docker Hub tag is that string. Upstream follows a rolling tag for the 11.0 line; this pins the
tag and its digest, and `11_1` is still beta. Back up, then edit both image lines:

```bash
cd ~/selfhost/otobo
docker compose pull
docker compose up -d
docker compose logs --tail 40 web
```

OTOBO migrates its schema on the way up: watch that log, then re-run step 7's asserts.

## 10. What will probably go wrong

The stack will be down and you will not know. I closed the lid on a Friday with two tickets on
an escalation clock, opened the dashboard on Monday, and both were the same age: nothing had
escalated because nothing had run. Containers on a laptop stop when the laptop stops, and the
daemon is the part that notices time passing. Turn on Docker Desktop's start-at-login setting,
run `docker compose up -d` after a restart, and read any age here as uptime.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP or IMAP. A laptop is not where a mail loop should live.
- Do not add an `elastic` service. Elasticsearch is optional upstream and ships off; it costs
  a JVM heap this machine lacks.
