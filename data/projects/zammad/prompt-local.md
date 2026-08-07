You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Zammad 7.1.2, with the PostgreSQL, Redis and memcached it needs, under
~/selfhost/zammad, answering at http://localhost:8169.

## 1. Preflight

Say this before step 2; it decides whether they want this at all. Only this computer can open
the helpdesk, so nobody they would support can reach it, and the scheduler that works the
queue stops whenever the machine sleeps.

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
ID and codename print next, for step 2. Zammad needs 6144 MB of RAM available and 20 GB free on
the home disk, upstream's minimum without Elasticsearch; both architectures are published. On
macOS and Windows raise Docker Desktop's memory to 6 GB first. Under either floor, print both
numbers and stop.

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
mkdir -p ~/selfhost/zammad/storage ~/selfhost/zammad/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 1000:1000 ~/selfhost/zammad/storage; fi
ls -la ~/selfhost/zammad
```

Assert: `ls -la` shows `storage` and `backups`. The Zammad image runs as uid 1000, so on
Linux `storage` is handed to it; elsewhere Docker Desktop's file sharing owns that and the
guarded line is a no-op. The database and Redis get Docker-managed volumes, those images
picking their own uids.

## 4. Secrets

One secret: the PostgreSQL password. Upstream ships `zammad` as its default, so this replaces a
published credential. Generate it here, print it nowhere, keep it out of summaries and logs.

```bash
umask 077
cat > ~/selfhost/zammad/.env <<EOF
ZAMMAD_FQDN=localhost:8169
ZAMMAD_HTTP_TYPE=http
POSTGRESQL_PASS=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/zammad/.env
umask 022
ls -l ~/selfhost/zammad/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so this runs the same everywhere, and no
human signs in with the value: the administrator account is made in a browser in step 7. On
Windows the mode bits are advisory and the user's account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/zammad/compose.yml <<'EOF'
# Zammad · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker compose ..... https://docs.zammad.org/en/latest/install/docker-compose.html
#   scenarios .......... https://docs.zammad.org/en/latest/install/docker-compose/docker-compose-scenarios.html
#   variable reference . https://docs.zammad.org/en/latest/appendix/environment-variables.html
#
# Seven services, every path relative to ~/selfhost/zammad/ so one file works
# on macOS, Linux and Windows. The database and Redis are named volumes, not
# bind mounts: both images chown their data directories to uids Docker
# Desktop's Windows file sharing cannot grant on a home-directory bind mount.
# Four of the seven are one Zammad image under different commands. Upstream's
# Elasticsearch, backup and migration containers are left out, the first
# through their ELASTICSEARCH_ENABLED switch. Digests read from Docker Hub 2026-08-07;
# every image publishes amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: zammad

# The four Zammad processes share one image; compose ignores x- keys.
x-zammad: &zammad
  image: zammad/zammad:7.1.2-0003@sha256:1ce0e929fac75f83f3e7534e9eb7aabfc3596cffbd00e25393be79709b9bea0c
  restart: unless-stopped
  init: true
  env_file: ./.env
  environment:
    POSTGRESQL_HOST: zammad-postgresql
    POSTGRESQL_DB: zammad_production
    POSTGRESQL_USER: zammad
    MEMCACHE_SERVERS: zammad-memcached:11211
    REDIS_URL: redis://zammad-redis:6379
    ELASTICSEARCH_ENABLED: "false"
    NGINX_SERVER_SCHEME: http
    RAILS_TRUSTED_PROXIES: 127.0.0.1,::1,172.16.0.0/12
  volumes:
    - ./storage:/opt/zammad/storage
  depends_on:
    zammad-postgresql:
      condition: service_healthy
    zammad-redis:
      condition: service_healthy
    zammad-memcached:
      condition: service_healthy

services:
  zammad-postgresql:
    image: postgres:17.10-alpine@sha256:742f40ea20b9ff2ff31db5458d127452988a2164df9e17441e191f3b72252193
    container_name: zammad-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zammad_production
      POSTGRES_USER: zammad
      POSTGRES_PASSWORD: ${POSTGRESQL_PASS}
    volumes:
      - zammad-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zammad -d zammad_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  zammad-redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: zammad-redis
    restart: unless-stopped
    volumes:
      - zammad-redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  zammad-memcached:
    image: memcached:1.6.45-alpine@sha256:c29847751abb41f4c268c84fb3087fee05d4edcbda44409ccb5086e26148e8a7
    container_name: zammad-memcached
    restart: unless-stopped
    command: memcached -m 256M
    healthcheck:
      test: ["CMD", "nc", "-z", "127.0.0.1", "11211"]
      interval: 10s
      retries: 12

  zammad-railsserver:
    <<: *zammad
    container_name: zammad-railsserver
    command: ["zammad-railsserver"]
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:3000"]
      interval: 30s
      start_period: 240s
      retries: 5

  zammad-websocket:
    <<: *zammad
    container_name: zammad-websocket
    command: ["zammad-websocket"]

  zammad-scheduler:
    <<: *zammad
    container_name: zammad-scheduler
    command: ["zammad-scheduler"]

  zammad-nginx:
    <<: *zammad
    container_name: zammad-nginx
    command: ["zammad-nginx"]
    init: false
    ports:
      # Loopback only: no other device on the wifi can reach 8169.
      - "127.0.0.1:8169:8080"
    depends_on:
      zammad-railsserver:
        condition: service_healthy

volumes:
  zammad-pgdata:
  zammad-redisdata:
EOF
cd ~/selfhost/zammad && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Seven services, one published port, two volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve.
- No TLS. Nothing has a public name to certify, and browsers treat http://localhost as a secure
  context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback.

8169 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not the internet.
For a queue of other people's problems that is the trade. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/zammad/compose.yml
```

Assert: that prints `1`, the one published port `- "127.0.0.1:8169:8080"`. PostgreSQL, Redis
and memcached publish none.

## 7. Start and verify

The migration container runs first, once, in the foreground: it creates the database, loads the
schema and seeds it. Expect minutes of output.

```bash
cd ~/selfhost/zammad
docker compose pull
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8169/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8169/api/v1/users
```

Assert all three, printing what you received: the init run exits 0, the loop ends on `200`, and
the unauthenticated call to /api/v1/users prints `401`, the security assert here. If any
misses, stop, run `docker compose logs --tail 40 zammad-railsserver` and name the cause. A
`502` that never becomes `200` means nginx is still waiting on the rails health check; `port is
already allocated` means something else holds 8169, which `lsof -nP -iTCP:8169` names on macOS
and Linux and `netstat -ano | findstr :8169` on Windows. A running container is not success.

The first screen at http://localhost:8169 shows the heading `Welcome!` above a button reading
`Set up a new system`.

STOP: tell the user to open http://localhost:8169, press `Set up a new system`, and work
through the wizard to create their administrator account, and wait.
Do not continue until they confirm. Tell them to put that password in a password manager as
they type it: there is no mail here and so no reset link.

Once they confirm, shut the self-signup door Zammad ships open, then prove both facts:

```bash
cd ~/selfhost/zammad
docker compose exec -T zammad-railsserver bundle exec rails r "Setting.set('user_create_account', false)"
curl -sS -H 'Content-Type: application/json' -d '{"query":"{systemSetupInfo{status}}"}' http://localhost:8169/graphql
curl -sS -H 'Content-Type: application/json' -d '{"query":"{applicationConfig{key value}}"}' http://localhost:8169/graphql | grep -q user_create_account && echo "signup OPEN" || echo "signup CLOSED"
```

Assert: the first curl prints `"status":"done"`, Zammad confirming an administrator now exists,
and the last prints `signup CLOSED`, because Zammad hands `user_create_account` to anonymous
browsers only while it is on. Both must pass.

## 8. First backup and restore

Two artifacts. Attachments live in the database on the default storage setting, so the dump is
all of the data; the config archive rebuilds the service around it.

```bash
cd ~/selfhost/zammad
docker compose exec -T zammad-postgresql pg_dump -U zammad -d zammad_production | gzip > ~/selfhost/zammad/backups/zammad-db-$(date +%F).sql.gz
tar -C ~/selfhost/zammad -czf ~/selfhost/zammad/backups/zammad-config-$(date +%F).tar.gz compose.yml .env storage
ls -lh ~/selfhost/zammad/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. Redis and memcached hold caches, so they are skipped.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination off this computer, a sync folder or a USB stick, and
copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: they confirm
both filenames are there, or say that this install has no backup.

To restore, in this order. `cd ~/selfhost/zammad`, untar the config archive there first so
compose.yml and .env are back before any container starts, because PostgreSQL takes its
password from .env the moment it initialises an empty volume. Then `docker compose down -v`,
the one place `-v` belongs, `docker compose up -d zammad-postgresql`, wait 30 seconds for
healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T zammad-postgresql psql -U zammad -d zammad_production`, run step 7's
init once, then `docker compose up -d`. That is the disaster plan.

## 9. Updating later

Image tags are at https://hub.docker.com/r/zammad/zammad/tags and versions at
https://github.com/zammad/zammad/tags. The tag carries a build number, which is why this pins
`7.1.2-0003`. Back up first, then edit the image line in ~/selfhost/zammad/compose.yml to the
new tag and digest:

```bash
cd ~/selfhost/zammad
docker compose pull
docker compose run --rm --user 0:0 zammad-railsserver zammad-init
docker compose up -d
docker compose logs --tail 30 zammad-railsserver
```

That init run is not optional: the new image migrates the database it inherited, and skipping
it leaves every container waiting on migrations nobody ran. Re-run step 7's checks after.

## 10. What will probably go wrong

I closed the laptop for an hour, came back, and a ticket I had raised showed no escalation and
no reminder. Nothing was broken: the machine had slept, Docker Desktop with it, and the
scheduler had not been running to notice anything was due. A reboot does the same, because
`restart: unless-stopped` acts only once the Docker daemon is up. Turn on Docker Desktop's
start-at-login, run `cd ~/selfhost/zammad && docker compose up -d` after one, and read every
escalation clock as "while this computer was awake".

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP, IMAP or POP3. Ticket-by-email needs a provider that can reach a public
  address, and nothing here has one.
- Do not add Elasticsearch. This stack is built without it, and it costs a container, four
  gigabytes and a reindex.
- Do not set `user_create_account` back to true, and do not rebind 8169 to 0.0.0.0 so a phone
  can reach it. Step 7 asserts signup is off; both undo that.
