You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Activepieces 0.86.3-hotfix.1, with its PostgreSQL and Redis, under
~/selfhost/activepieces, answering at http://localhost:8095.

## 1. Preflight

Say this before step 2 runs; it decides whether the user wants this install. Schedules and
polling triggers work, while the machine is awake. Webhook triggers do not: the URL handed to a
third party starts http://localhost:8095, which nothing outside this computer can deliver to.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. On Linux the
distribution ID and codename print next, for step 2. This install needs 4096 MB of RAM
available and 20 GB free on the home disk; all three images publish amd64 and arm64. On macOS
and Windows that figure is the host's, out of which Docker Desktop takes its share. Under
either floor, print both numbers and stop.

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
mkdir -p ~/selfhost/activepieces/backups ~/selfhost/activepieces/cache
ls -la ~/selfhost/activepieces
```

Assert: `ls -la` shows `backups` and `cache`, both owned by the user. There is no `data`
folder: flows and queue live in volumes Docker manages.

## 4. Secrets

Three secrets: the encryption key protecting stored connection credentials, the JWT signing
secret, and the PostgreSQL password. Generate all three here, print none, and keep them out of
your summary and any log line. Upstream documents the encryption key as 32 hex characters,
`-hex 16`; that length is not optional.

```bash
umask 077
cat > ~/selfhost/activepieces/.env <<EOF
AP_FRONTEND_URL=http://localhost:8095
AP_ENCRYPTION_KEY=$(openssl rand -hex 16)
AP_JWT_SECRET=$(openssl rand -hex 32)
AP_POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/activepieces/.env
umask 022
ls -l ~/selfhost/activepieces/.env
```

Assert: the file exists with mode `-rw-------`; Git Bash ships openssl, so this runs the same
everywhere. Every credential the user hands a piece is encrypted with that key, so tell them to
put it in their password manager tonight, read with
`grep AP_ENCRYPTION_KEY ~/selfhost/activepieces/.env`. On Windows those mode bits are advisory
and the real boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/activepieces/compose.yml <<'EOF'
# Activepieces · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   compose install ..... https://www.activepieces.com/docs/install/options/docker-compose
#   variable reference .. https://www.activepieces.com/docs/install/reference/environment-variables
#   sizing and sandbox .. https://www.activepieces.com/docs/install/configure-operate/production-setup
#
# Three services, every path relative to ~/selfhost/activepieces/ so one file
# works on macOS, Linux and Windows. One image runs the API and the worker;
# PostgreSQL is the pgvector image because the knowledge base asks for that
# extension at boot. AP_EXECUTION_MODE is upstream's choice for single-tenant and
# the image default: flow code runs with this container's reach, home network
# included. 8095 binds to loopback and AP_FRONTEND_URL is http://localhost:8095,
# this computer only. Digests read 2026-08-05; all three publish amd64 and arm64.
#
# Two named volumes rather than bind mounts: PostgreSQL chowns its data directory
# to its own uid and Redis chowns /data to the redis user, and Docker Desktop's
# Windows file sharing grants neither on a home-directory bind mount. The piece
# cache stays a relative bind, visible in Finder or Explorer.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg16@sha256:a36250871de0833b8757561c72f2477ef1ddd1101afa4e617fb552e0de514c6b
    container_name: activepieces-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: activepieces
      POSTGRES_USER: activepieces
      POSTGRES_PASSWORD: ${AP_POSTGRES_PASSWORD}
    volumes:
      - activepieces-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U activepieces -d activepieces"]
      interval: 10s
      retries: 12

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: activepieces-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - activepieces-redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  activepieces:
    image: ghcr.io/activepieces/activepieces:0.86.3-hotfix.1@sha256:4da6910cf46dbc38857c8c4fac6ba867ab804b8a3a8551d672d4490cb1245566
    container_name: activepieces
    restart: unless-stopped
    env_file: ./.env
    environment:
      AP_ENVIRONMENT: prod
      AP_CONTAINER_TYPE: WORKER_AND_APP
      AP_DB_TYPE: POSTGRES
      AP_POSTGRES_HOST: postgres
      AP_POSTGRES_PORT: "5432"
      AP_POSTGRES_DATABASE: activepieces
      AP_POSTGRES_USERNAME: activepieces
      AP_REDIS_TYPE: STANDALONE
      AP_REDIS_HOST: redis
      AP_REDIS_PORT: "6379"
      AP_EXECUTION_MODE: UNSANDBOXED
      AP_WORKER_CONCURRENCY: "1"
      AP_QUEUE_UI_ENABLED: "false"
      AP_TELEMETRY_ENABLED: "false"
    volumes:
      - ./cache:/usr/src/app/cache
    ports:
      - "127.0.0.1:8095:80"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  activepieces-pgdata:
  activepieces-redisdata:
EOF
cd ~/selfhost/activepieces && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

Three absences, each a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8095 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. That is the point of this path, and why a webhook has nowhere to arrive.

```bash
grep -n '127.0.0.1' ~/selfhost/activepieces/compose.yml
```

Assert: one line, `- "127.0.0.1:8095:80"`.

## 7. Start and verify

Activepieces runs its migrations, then syncs the piece catalogue metadata, so first boot is
slow. The image's health check waits 60 seconds before it asks.

```bash
cd ~/selfhost/activepieces
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8095/api/v1/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8095/api/v1/health
curl -sS http://localhost:8095/api/v1/flags | grep -o '"USER_CREATED":[a-z]*' || echo "USER_CREATED absent"
```

Assert all three, and print what you received for each: the loop ends on `200`; the health
response is exactly `{"status":"Healthy"}`; the flags call prints `USER_CREATED absent`, which
is how a fresh instance says nobody has registered. If any misses, stop, run
`docker compose logs --tail 40 activepieces` and `docker compose logs --tail 20 postgres`, and
name the likely cause: a database that never reports healthy points at step 4. If
`port is already allocated` came back, find what holds 8095 with
`lsof -nP -iTCP:8095 -sTCP:LISTEN` and stop until it is free. A running container is not
success.

The first screen is at http://localhost:8095/sign-up and shows the heading
`Create a new account` over a form asking for a first name, a last name, an email and a
password.

STOP: tell the user to open that URL, create the first account, and wait. Do not continue until
they confirm. That account owns the instance. Then confirm registration closed:

```bash
curl -sS http://localhost:8095/api/v1/flags | grep -o '"USER_CREATED":true'
```

Assert: that prints `"USER_CREATED":true`. A second sign-up is now answered against the
platform the first account created, and that path needs an invitation unless
`AP_ALLOW_OPEN_SIGN_UP` is set, which this install never does. Both asserts must pass.

## 8. First backup and restore

Two artifacts: a database dump with the flows, connections and run history, and a config
archive with the two files that rebuild the service around it, encryption key included.

```bash
cd ~/selfhost/activepieces
docker compose exec -T postgres pg_dump -U activepieces -d activepieces | gzip > ~/selfhost/activepieces/backups/activepieces-db-$(date +%F).sql.gz
tar -C ~/selfhost/activepieces -czf ~/selfhost/activepieces/backups/activepieces-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/activepieces/backups/
```

Assert: both files exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. Redis is not backed up: it carries jobs in flight,
not the flows.

Both archives sit on the same disk as the data, and on a laptop disk and machine fail together.
Ask for a destination that leaves this computer, a sync folder or a USB stick, and copy both
there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: the user confirms both
filenames are listed there. If they have neither, say plainly that this install has no backup.

To restore. `cd ~/selfhost/activepieces` and untar the config archive there first, so
compose.yml and .env are back before any container starts: PostgreSQL reads
`AP_POSTGRES_PASSWORD` from .env the moment it initialises an empty volume. Then
`docker compose down -v`, the one place `-v` belongs, `docker compose up -d postgres`, wait 30
seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U activepieces -d activepieces`, then
`docker compose up -d` and re-run step 7's health check. Restored without the matching
`AP_ENCRYPTION_KEY`, that database comes back with every flow intact and nothing able to run.

## 9. Updating later

New versions are listed at https://github.com/activepieces/activepieces/releases. Back up
first, then edit the image line in compose.yml to the new tag and digest:

```bash
cd ~/selfhost/activepieces
docker compose pull
docker compose up -d
docker compose logs --tail 30 activepieces
```

Watch that log until it settles, then re-run the health check.

## 10. What will probably go wrong

I closed the lid on a Friday and came back Monday to a flow that had not run since. Nothing
crashed: a scheduled trigger fires only while this computer is awake and Docker is up, and a
sleeping laptop is neither. `restart: unless-stopped` acts only once the daemon is running, so
a reboot without Docker Desktop's start-at-login setting leaves nothing on 8095. Turn that
setting on, and after a reboot run `cd ~/selfhost/activepieces && docker compose up -d` before
concluding anything is wrong.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not install a tunnel to make webhook triggers reachable, and do not rebind 8095 to
  0.0.0.0. Either puts a machine holding every credential the user connected onto a network.
- Do not configure SMTP, `AP_GOOGLE_CLIENT_ID`, or any SSO variable. First login is an email
  address and a password; SSO is a paid-edition feature.
- Do not change `AP_EXECUTION_MODE` or `AP_NETWORK_MODE`. Upstream states the strict guard is
  best-effort in-process, not a boundary against hostile code.
