You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Zulip Server 12.2 under ~/selfhost/zulip, answering at http://localhost:8192.

## 1. Preflight

Say this before step 2, because it decides whether they want this install at all. Zulip is a
team chat server, and this one answers at http://localhost:8192: nobody they invite can reach
it, and neither can the Zulip app on their phone. They get a real Zulip to write in and search,
on a machine they own.

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
distribution ID and codename print next, for step 2. Zulip needs 4096 MB of RAM available and
20 GB free on the home disk; every image publishes amd64 and arm64. On macOS and Windows give
Docker Desktop 4 GB in its settings first. Under either floor, print both and stop.

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
mkdir -p ~/selfhost/zulip/data ~/selfhost/zulip/backups
ls -la ~/selfhost/zulip
```

Assert: `ls -la` shows `data` and `backups`. Nothing needs chowning here: Zulip runs as root
and makes `uploads` and `zulip-secrets.conf` under `data`, and the others take named volumes
because they chown to uids a home mount cannot grant.

## 4. Secrets

Five: the PostgreSQL, memcached, RabbitMQ and Redis passwords the containers authenticate to
each other with, plus the Django key that seals every session. Do not print them, repeat them,
or log them.

```bash
umask 077
cat > ~/selfhost/zulip/.env <<EOF
ZULIP_ADMIN_EMAIL=admin@localhost
ZULIP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
ZULIP_MEMCACHED_PASSWORD=$(openssl rand -hex 32)
ZULIP_RABBITMQ_PASSWORD=$(openssl rand -hex 32)
ZULIP_REDIS_PASSWORD=$(openssl rand -hex 32)
ZULIP_SECRET_KEY=$(openssl rand -hex 32)
MEMCACHED_SASL_DB=/home/memcache/memcached-sasl-db
EOF
chmod 600 ~/selfhost/zulip/.env
umask 022
ls -l ~/selfhost/zulip/.env
```

Assert: mode `-rw-------`. On Windows those bits are advisory and the real boundary is the
user's own account. No outgoing mail is configured, so nothing is ever sent to
`ZULIP_ADMIN_EMAIL` and the step 7 account has no password reset. Say that before the password
is chosen, not after.

## 5. compose.yml

```bash
cat > ~/selfhost/zulip/compose.yml <<'EOF'
# Zulip · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a
# repository:
#   variables ... https://zulip.readthedocs.io/projects/docker/en/latest/reference/environment-vars.html
#   entrypoint .. https://github.com/zulip/docker-zulip/blob/12.2-0/entrypoint.sh
#
# The same five services upstream runs, on the computer you are sitting at.
# The uploads-and-secrets directory is a relative bind mount so you can open
# it in Finder or Explorer; the other three take named volumes because those
# images chown directories to uids Docker Desktop cannot grant on a home
# folder. Otherwise the server file differs only in EXTERNAL_HOST carrying
# the served port, an http URI scheme, no TRUST_GATEWAY_IP, and no mail.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  database:
    image: zulip/zulip-postgresql:14@sha256:e71ba8616fa42cdc1b248f51263d9290c29681cb8c1992eb9b498af0bb656b29
    restart: unless-stopped
    environment:
      POSTGRES_DB: zulip
      POSTGRES_USER: zulip
      POSTGRES_PASSWORD: ${ZULIP_POSTGRES_PASSWORD}
    volumes:
      - postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zulip -d zulip"]
      interval: 10s
      retries: 12

  memcached:
    image: memcached:1.6.45-alpine@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7
    restart: unless-stopped
    # SASL: Zulip authenticates as zulip@localhost, as upstream sets up.
    command:
      - "sh"
      - "-euc"
      - |
        echo 'mech_list: plain' > /home/memcache/memcached.conf
        echo "zulip@$$HOSTNAME:$$MEMCACHED_PASSWORD" > "$$MEMCACHED_SASL_PWDB"
        echo "zulip@localhost:$$MEMCACHED_PASSWORD" >> "$$MEMCACHED_SASL_PWDB"
        exec memcached -S
    environment:
      SASL_CONF_PATH: /home/memcache/memcached.conf
      MEMCACHED_SASL_PWDB: ${MEMCACHED_SASL_DB}
      MEMCACHED_PASSWORD: ${ZULIP_MEMCACHED_PASSWORD}

  rabbitmq:
    image: rabbitmq:4.2.9@sha256:0104af7ef0d2bfff20b1e84a7177320d9b990531624d6b63f9dcf82d6de3b61b
    hostname: rabbitmq
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: zulip
      RABBITMQ_DEFAULT_PASS: ${ZULIP_RABBITMQ_PASSWORD}
    volumes:
      - rabbitmq:/var/lib/rabbitmq

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    restart: unless-stopped
    command:
      - "sh"
      - "-euc"
      - 'exec /usr/local/bin/docker-entrypoint.sh redis-server --requirepass "$$REDIS_PASSWORD"'
    environment:
      REDIS_PASSWORD: ${ZULIP_REDIS_PASSWORD}
    volumes:
      - redis:/data

  zulip:
    image: ghcr.io/zulip/zulip-server:12.2-0@sha256:765f0ab3caa49041989132ee1879d98dbab1df7695c27e713eac1f114d167755
    container_name: zulip
    restart: unless-stopped
    environment:
      # CERTIFICATES absent means plain HTTP on 80; the host and scheme
      # below are what Zulip prints into every link.
      SETTING_EXTERNAL_HOST: localhost:8192
      SETTING_EXTERNAL_URI_SCHEME: "http://"
      SETTING_ZULIP_ADMINISTRATOR: ${ZULIP_ADMIN_EMAIL}
      SETTING_REMOTE_POSTGRES_HOST: database
      SETTING_MEMCACHED_LOCATION: memcached:11211
      SETTING_RABBITMQ_HOST: rabbitmq
      SETTING_REDIS_HOST: redis
      ZULIP_AUTH_BACKENDS: EmailAuthBackend
      # Upstream's small-deploy override; the default costs a gigabyte.
      CONFIG_application_server__queue_workers_multiprocess: "False"
      SECRETS_postgres_password: ${ZULIP_POSTGRES_PASSWORD}
      SECRETS_memcached_password: ${ZULIP_MEMCACHED_PASSWORD}
      SECRETS_rabbitmq_password: ${ZULIP_RABBITMQ_PASSWORD}
      SECRETS_redis_password: ${ZULIP_REDIS_PASSWORD}
      SECRETS_secret_key: ${ZULIP_SECRET_KEY}
    volumes:
      - ./data:/data
    ulimits:
      nofile:
        soft: 1000000
        hard: 1048576
    ports:
      # Loopback only: no other device on the wifi reaches 8192.
      - "127.0.0.1:8192:80"
    depends_on:
      database:
        condition: service_healthy
      memcached:
        condition: service_started
      rabbitmq:
        condition: service_started
      redis:
        condition: service_started

volumes:
  postgres:
  rabbitmq:
  redis:
EOF
cd ~/selfhost/zulip && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Five services, one published port, one bind mount, no secret:
every value comes as `${...}` from the `.env` beside it.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. A certificate
attests a public name nothing here has, and nothing is published beyond loopback:

```bash
grep -c '"127.0.0.1:' ~/selfhost/zulip/compose.yml
```

Assert: that prints `1`, the single published port `127.0.0.1:8192:80`. The other four publish
nothing and talk over the compose network. No phone, no laptop on the wifi and nobody on the
internet reaches this, which for a team chat server is the trade.

One consequence before step 7: Zulip runs in production mode, so its session cookie is `Secure`
with a `__Host-` prefix. Browsers treat http://localhost as trustworthy and store it anyway,
which is what makes this work without TLS. A login form that keeps returning after a correct
password means yours does not; try Chrome.

## 7. Start and verify

Upstream boots this in two moves: a one-shot container that validates and migrates, then the
server. The first fails loudly, the second slowly.

```bash
cd ~/selfhost/zulip
docker compose pull
docker compose run --rm zulip app:init
```

Assert: the last line is `=== End Initial Configuration Phase ===`. The pull is gigabytes and
the init migrates an empty database, so this is the long step. Anything else, stop and read
the output.

```bash
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8192/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8192/health; echo
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8192/
curl -sS http://localhost:8192/new/ | grep -c 'Organization creation link required'
```

Assert all four and print what you got. The loop ends on `200`; that endpoint queries
PostgreSQL, round-trips memcached, pings Redis and opens a RabbitMQ channel, so one `200` is
all five answering. The body is `{"result":"success","msg":""}`. The root prints `404`, headed
`No organization found`. The grep prints `1`: `OPEN_REALM_CREATION` is off by default. If the
loop never reaches `200`, read `docker compose logs --tail 60 zulip`; if
`port is already allocated` came back, find what holds 8192 (`ss -ltnp | grep 8192` on Linux,
`lsof -nP -iTCP:8192` on macOS) and stop until the user frees it.

The way in is a single-use link made by the server:

```bash
docker compose exec -T -u zulip zulip /home/zulip/deployments/current/manage.py generate_realm_creation_link | grep -o 'http://[^[:space:]]*/new/[A-Za-z0-9]*'
```

Assert: one line beginning `http://localhost:8192/new/`. Print it: it never leaves this machine
and expires in a week.

STOP: tell the user to open that link and complete the page headed
`Create a new Zulip organization` with their organization name, their own address, and a
password saved to their password manager first.
Do not continue until they confirm they are signed in. There is no mail here, so that password
has no reset link.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8192/
curl -sS http://localhost:8192/new/ | grep -c 'Organization creation link required'
```

Assert both. The root prints `200`, so the organization exists. The grep prints `1` again: the
link was spent, the page is still shut, and the realm is invite-only by default. A running
container is not success.

## 8. First backup and restore

`app:backup` writes a fresh dump into the data directory; the tar carries it, the uploads, the
secrets file, `.env` and compose.yml out.

```bash
cd ~/selfhost/zulip
docker compose exec -T zulip /sbin/entrypoint.sh app:backup
if [ "$(uname -s)" = "Linux" ]; then SUDO=sudo; else SUDO=; fi
$SUDO tar -C ~/selfhost/zulip -czf ~/selfhost/zulip/backups/zulip-$(date +%F).tar.gz compose.yml .env data
ls -lh ~/selfhost/zulip/backups/
```

Assert: the archive exists and is non-empty. Print its size. Nothing is stopped: `pg_dump`
snapshots a running database consistently, and the cluster volume is not copied because the
dump inside is the restorable form. The `sudo` on Linux is not optional: the container writes
into `data` as root, and only Docker Desktop maps that back to the user. Use it on restore too.

That archive is on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB
stick, and copy it there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms the filename is there. Nowhere means no backup.

To restore: `cd ~/selfhost/zulip`, `docker compose down -v`, untar the archive there so `.env`
is back first, `docker compose up -d database`, wait thirty seconds,
`docker compose run --rm zulip app:restore <filename>` naming a `backup-*.sql` file from
`data/backups`, then `docker compose up -d`. The dump is every message, `data/uploads` every
shared file, `data/zulip-secrets.conf` what lets the server know its own sessions.

## 9. Updating later

New versions: https://github.com/zulip/docker-zulip/releases. Upstream publishes no floating
tags, so an update is deliberate: back up, then change the image line to the new tag.

```bash
cd ~/selfhost/zulip
docker compose pull
docker compose up -d
docker compose logs --tail 40 zulip
```

Zulip migrates on the way up. Watch that log until it settles, re-run step 7's `/health` check,
and move one major at a time.

## 10. What will probably go wrong

The machine runs out of memory before it runs out of patience. I gave Docker Desktop its
default allocation, started all five containers, and watched the Zulip container get killed
twice during migrations with nothing in the log but a truncated line, which reads exactly like
a crash and is not one. Open Docker Desktop's resources, give it 4 GB, and run
`docker compose up -d` again. The same shortage shows up a second way, as a first boot that
seems to hang: ten minutes is normal, so let the step 7 loop finish.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure outgoing mail. Without a relay Zulip drops its mail quietly.
- Do not rebind 8192 to 0.0.0.0 for a phone on the wifi. That puts a chat server on every
  network this machine joins.
- Do not register for the mobile push service. A server nothing can reach has nothing to push.
