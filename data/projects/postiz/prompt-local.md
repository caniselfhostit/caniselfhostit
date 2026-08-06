You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Postiz 2.23.0, with the PostgreSQL, Redis and Temporal it needs, under
~/selfhost/postiz, answering at http://localhost:8111.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this install at all.
Posting to a network needs an app the user registers at that company's developer portal,
and each wants a redirect URI it can reach; here that is a localhost address some portals
reject. A post scheduled for 9am does not go out if the laptop is asleep.

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux
the distribution ID and codename print next, for step 2. This stack needs 4096 MB of RAM
available and 20 GB free on the home disk, upstream's own guidance once PostgreSQL, Redis
and the workflow engine share a host. All four images are amd64 and arm64. If RAM is under
4096 MB or free disk is under 20 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/postiz/backups ~/selfhost/postiz/config ~/selfhost/postiz/uploads
ls -la ~/selfhost/postiz
```

Assert: three directories, all owned by the user. The databases and the cache live in
volumes Docker manages, so nothing here needs an ownership fix.

## 4. Secrets

Three: a password for each PostgreSQL, and the key that signs session tokens. Generate them
here, print none of them, and keep all three out of your summary and every log line.

```bash
umask 077
cat > ~/selfhost/postiz/.env <<EOF
POSTIZ_DB_PASSWORD=$(openssl rand -hex 32)
TEMPORAL_DB_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 48)
EOF
chmod 600 ~/selfhost/postiz/.env
umask 022
ls -l ~/selfhost/postiz/.env
```

Assert: mode `-rw-------`. Compose reads this file from the working directory, so every
command from here runs with ~/selfhost/postiz as that directory. On Windows those mode bits
are advisory: NTFS does not enforce them, and the boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/postiz/compose.yml <<'EOF'
# Postiz · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   compose install ....... https://docs.postiz.com/installation/docker-compose
#   variable reference .... https://docs.postiz.com/configuration/reference
#   system requirements ... https://docs.postiz.com/installation/system-requirements
#   temporal, sql only .... https://github.com/temporalio/docker-compose/blob/main/docker-compose-postgres.yml
#
# Five services on the computer you are sitting at, every path relative to
# ~/selfhost/postiz/ so one file works on macOS, Linux and Windows. Temporal has
# been required since v2.12.0 and keeps its workflow history in a database of
# its own, so the two PostgreSQL services differ. Three named volumes, because
# PostgreSQL and Redis chown their data directory to a uid of their own and
# Docker Desktop cannot grant that on a Windows home-directory bind mount;
# uploads and config stay relative binds. Digests read 2026-08-06, multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: postiz

services:
  postiz-postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: postiz
      POSTGRES_USER: postiz
      POSTGRES_PASSWORD: ${POSTIZ_DB_PASSWORD}
    volumes:
      - postiz-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postiz -d postiz"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  postiz-redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - postiz-redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  temporal-postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_USER: temporal
      POSTGRES_PASSWORD: ${TEMPORAL_DB_PASSWORD}
    volumes:
      - temporal-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U temporal"]
      interval: 10s
      retries: 12

  temporal:
    image: temporalio/auto-setup:1.28.1@sha256:607d68caa111338d754771efb876c92dfcdae06d056e4530bb31cd0f37406e6a
    restart: unless-stopped
    environment:
      # postgres12 names the driver, not a version floor.
      DB: postgres12
      DB_PORT: "5432"
      POSTGRES_USER: temporal
      POSTGRES_PWD: ${TEMPORAL_DB_PASSWORD}
      POSTGRES_SEEDS: temporal-postgres
    # No dynamic-config mount: the image ships its own, and Postiz overrides
    # nothing in it.
    healthcheck:
      test: ["CMD", "temporal", "operator", "cluster", "health", "--address", "temporal:7233"]
      interval: 10s
      retries: 30
    depends_on:
      temporal-postgres:
        condition: service_healthy

  postiz:
    image: ghcr.io/gitroomhq/postiz-app:v2.23.0@sha256:785f97312f66a347fb96cdccc4ded5a33ced69a672c89a9adc8054e7d6a21dc5
    restart: unless-stopped
    environment:
      # /api because the container's nginx routes /api/ to the backend.
      FRONTEND_URL: "http://localhost:8111"
      NEXT_PUBLIC_BACKEND_URL: "http://localhost:8111/api"
      BACKEND_INTERNAL_URL: "http://localhost:3000"
      DATABASE_URL: "postgresql://postiz:${POSTIZ_DB_PASSWORD}@postiz-postgres:5432/postiz"
      REDIS_URL: "redis://postiz-redis:6379"
      JWT_SECRET: ${JWT_SECRET}
      TEMPORAL_ADDRESS: "temporal:7233"
      # RUN_CRON registers the workflows that post on a schedule.
      IS_GENERAL: "true"
      RUN_CRON: "true"
      # One signup while the database is empty, then the page shuts.
      DISABLE_REGISTRATION: "true"
      STORAGE_PROVIDER: "local"
      UPLOAD_DIRECTORY: "/uploads"
      NEXT_PUBLIC_UPLOAD_STATIC_DIRECTORY: "/uploads"
    volumes:
      - ./config:/config
      - ./uploads:/uploads
    ports:
      # Loopback only: no other device on the wifi can reach 8111.
      - "127.0.0.1:8111:5000"
    depends_on:
      postiz-postgres:
        condition: service_healthy
      postiz-redis:
        condition: service_healthy
      temporal:
        condition: service_healthy

volumes:
  postiz-pgdata:
  postiz-redisdata:
  temporal-pgdata:
EOF
cd ~/selfhost/postiz && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK` and nothing else.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. There is no hostname to resolve, and a
certificate attests a public name that nothing here has; browsers treat http://localhost as
a secure context anyway, so pages needing crypto still work.

The one published line in compose.yml is `- "127.0.0.1:8111:5000"`: not the user's phone,
not a laptop on the same wifi, not anyone on the internet. Nothing else publishes a host
port, so 5432, 6379 and 7233 cannot appear.

## 7. Start and verify

The first start is slow: Temporal builds two schemas, then Postiz migrates.

```bash
cd ~/selfhost/postiz
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8111/api/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
docker compose exec -T temporal temporal operator cluster health --address temporal:7233
curl -sS http://localhost:8111/api/
curl -sS http://localhost:8111/api/auth/can-register
```

Assert all four, printing what you received for each: the loop ends on `200`, the Temporal
check prints `SERVING`, the third prints `App is running!`, the fourth prints
`{"register":true}` because the database holds no account yet. If any misses, stop, run
`docker compose logs --tail 40 postiz` and `docker compose logs --tail 20 temporal`, and
name the likely cause: a Temporal container stuck below healthy points at step 4, where an
empty password leaves its PostgreSQL refusing connections. A running container is not
success.

The first screen is http://localhost:8111/auth: the heading `Sign Up` over an email,
password and company form, with a `Create Account` button.

STOP: tell the user to open http://localhost:8111/auth, create the one account this install
will have, and wait. Do not continue until they confirm. Then check the window shut:

```bash
curl -sS http://localhost:8111/api/auth/can-register
```

Assert: `{"register":false}`. Upstream documents `DISABLE_REGISTRATION`, which compose.yml
sets, as allowing one signup and then closing the sign-up page. Have them reload the page
and confirm it reads `Registration is disabled`. Both pass before you claim success.

## 8. First backup and restore

Two artifacts: the dump holds accounts, drafts and the schedule, the archive holds the
files that rebuild the service around it, media included.

```bash
cd ~/selfhost/postiz
docker compose exec -T postiz-postgres pg_dump -U postiz -d postiz | gzip > ~/selfhost/postiz/backups/postiz-db-$(date +%F).sql.gz
tar -C ~/selfhost/postiz -czf ~/selfhost/postiz/backups/postiz-config-$(date +%F).tar.gz compose.yml .env config uploads
ls -lh ~/selfhost/postiz/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing stops: `pg_dump` snapshots
a running database consistently, and Temporal's database is in neither: auto-setup rebuilds
it.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and
the machine fail together. Ask the user for a destination off this computer, a sync folder
or a USB stick, and copy both there with `cp`. Assert: the user confirms both are
listed there.

To restore, in this order. `cd ~/selfhost/postiz`, untar the archive there first so
compose.yml and .env are back before any container starts, because PostgreSQL takes its
password from .env the moment it initialises an empty volume. Then `docker compose down -v`,
`docker compose up -d postiz-postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on
the `.sql.gz` into `docker compose exec -T postiz-postgres psql -U postiz -d postiz`, then
`docker compose up -d`.

## 9. Updating later

New versions are listed at https://github.com/gitroomhq/postiz-app/releases. Take both
backups first, then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/postiz
docker compose pull
docker compose up -d
docker compose logs --tail 30 postiz
```

Watch that log until it settles, then re-run the four checks from step 7.

## 10. What will probably go wrong

I closed the lid on a Tuesday evening with a post scheduled for Wednesday morning, and on
Wednesday afternoon it was still in the calendar. Nothing was broken: a scheduled post is a
Temporal workflow, and a sleeping machine runs no containers. Docker Desktop not starting
after a reboot gives the same silence. Run `docker compose ps` before concluding
anything.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not connect a social network, and do not create developer accounts or apps for the
  user. Each needs an app registered in that company's own developer portal and its keys
  added to ~/selfhost/postiz/.env, several are reviewed by a person and take days, and here
  the redirect URI is a localhost address some portals reject. Say that in your summary,
  with https://docs.postiz.com/providers/overview.
