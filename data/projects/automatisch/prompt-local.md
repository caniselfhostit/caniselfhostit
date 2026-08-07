You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Automatisch 0.15.0, with the PostgreSQL and Redis it runs on, under
~/selfhost/automatisch, at http://localhost:8171.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Automatisch checks its triggers every fifteen minutes and only while this computer is awake, so a
sleeping machine runs no flows, and the webhook address it hands a third party begins with
http://localhost:8171, which nothing outside can reach. The polling half is what works here.

Detect the OS and measure the machine.

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
distribution ID and codename print next, for step 2. This install needs 2048 MB of RAM available
and 10 GB free on the home disk, and all three images publish amd64 and arm64. On macOS and
Windows that figure is the host's, and Docker Desktop takes its share of it. If it is under
2048 MB, or disk under 10 GB, print both and stop.

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
mkdir -p ~/selfhost/automatisch/backups
ls -la ~/selfhost/automatisch
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: flows and run
history are rows in PostgreSQL and the queue is in Redis, both in volumes Docker manages, so
nothing here needs a chown.

## 4. Secrets

Four secrets: the key that encrypts every stored third-party credential, the key that verifies
inbound webhooks, the app secret key upstream documents as required, and the PostgreSQL password.
Generate all four here, print none, keep them out of your summary and any log.

```bash
umask 077
cat > ~/selfhost/automatisch/.env <<EOF
API_URL=http://localhost:8171
ENCRYPTION_KEY=$(openssl rand -hex 32)
WEBHOOK_SECRET_KEY=$(openssl rand -hex 32)
APP_SECRET_KEY=$(openssl rand -hex 32)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/automatisch/.env
umask 022
ls -l ~/selfhost/automatisch/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same everywhere. Upstream's warning about the first two is worth repeating: change them and
existing connections and flows stop working. `ENCRYPTION_KEY` belongs in a password manager
tonight, read with `grep ENCRYPTION_KEY ~/selfhost/automatisch/.env`. On Windows those mode bits
are advisory: NTFS ignores them, and the user's own account is the boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/automatisch/compose.yml <<'EOF'
# Automatisch · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installation ....... https://automatisch.io/docs/guide/installation
#   variable reference . https://automatisch.io/docs/advanced/configuration
#   url resolution ..... https://github.com/automatisch/automatisch/blob/v0.15.0/packages/backend/src/config/app.js
#
# Four services on the computer you are sitting at. One image runs twice: as the
# web and API process, and with WORKER=true as the queue worker, the split
# upstream documents for Docker. Two named volumes rather than bind mounts,
# because PostgreSQL and the Redis entrypoint both chown their data directory and
# Docker Desktop's Windows file sharing grants neither on a home-directory bind
# mount. API_URL is http://localhost:8171, this computer only; config/app.js
# builds the API base, the web app URL and the webhook URL from it. Digests read
# 2026-08-07; all images publish arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# Both app services share an image; compose ignores x- keys.
x-automatisch-env: &automatisch-env
  APP_ENV: production
  POSTGRES_HOST: postgres
  POSTGRES_DATABASE: automatisch
  POSTGRES_USERNAME: automatisch
  REDIS_HOST: redis
  # No seeded admin: the first account is made on the installation screen.
  DISABLE_SEED_USER: "true"
  TELEMETRY_ENABLED: "false"

x-automatisch: &automatisch
  image: ghcr.io/automatisch/automatisch:0.15.0@sha256:3bace7a12d5fb3f5b1305a6a52232270e0e0abd8465a8b78baacb07f6ea89594
  restart: unless-stopped
  env_file: ./.env
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: automatisch-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: automatisch
      POSTGRES_USER: automatisch
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - automatisch-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U automatisch -d automatisch"]
      interval: 10s
      retries: 12

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: automatisch-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - automatisch-redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12

  automatisch:
    <<: *automatisch
    container_name: automatisch
    environment: *automatisch-env
    ports:
      - "127.0.0.1:8171:3000"

  worker:
    <<: *automatisch
    container_name: automatisch-worker
    environment:
      # This copy runs the queue, not the web process.
      <<: *automatisch-env
      WORKER: "true"

volumes:
  automatisch-pgdata:
  automatisch-redisdata:
EOF
cd ~/selfhost/automatisch && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Four services, one published port, two named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule: no hostname to resolve, no public name for a
certificate to attest, nothing beyond loopback to close. Browsers treat http://localhost as a
secure context, so pages needing crypto still work.

8171 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not anyone on the
internet, not a third party calling a webhook. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/automatisch/compose.yml
```

Assert: that prints `1`, the single published port line. PostgreSQL and Redis publish no host
port, so 5432 and 6379 cannot appear.

## 7. Start and verify

The main container migrates the database on the way up, so first boot is slow.

```bash
cd ~/selfhost/automatisch
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8171/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8171/internal/api/v1/automatisch/version
docker compose logs --tail 20 worker | grep -c 'Workers are ready'
```

Assert all three, and print what you received for each: the loop ends on `200`; the version
response contains `"version":"0.15.0"`; the worker count is `1`. If any miss, stop, run
`docker compose logs --tail 40 automatisch`, and name the cause: a database that never reports
healthy points at step 4, where an empty `POSTGRES_PASSWORD` leaves PostgreSQL refusing to start;
a log still in migrations wants time; `port is already allocated` means something else holds
8171, so stop until the user frees it. A running container is not success.

The first screen is at http://localhost:8171/installation, and http://localhost:8171/ redirects
to it while the instance has no account. It shows the heading `Installation` over a form asking
for a full name, an email and a password twice, above a button reading `Create admin`.

STOP: tell the user to open http://localhost:8171/ and fill that form in, and wait.
Do not continue until they confirm. Then confirm the door shut:

```bash
curl -sS http://localhost:8171/internal/api/v1/automatisch/info | grep -o '"installationCompleted":true'
```

Assert: that prints `"installationCompleted":true`, which is a fresh instance saying it now has
an owner. That endpoint answers `403` from here on, and `DISABLE_SEED_USER` means the account
upstream's entrypoint seeds by default never existed. Both asserts must pass.

## 8. First backup and restore

Two artifacts: a database dump with the flows, connections and run history, and a config archive
with the two files that rebuild the service around it.

```bash
cd ~/selfhost/automatisch
docker compose exec -T postgres pg_dump -U automatisch -d automatisch | gzip > ~/selfhost/automatisch/backups/automatisch-db-$(date +%F).sql.gz
tar -C ~/selfhost/automatisch -czf ~/selfhost/automatisch/backups/automatisch-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/automatisch/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently. Both archives sit on the same disk as the data, which
is not a backup, and on a laptop disk and machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy both there with `cp`. Assert: the user
confirms both filenames are listed there. If neither is, say plainly that there is no backup.

To restore: `cd ~/selfhost/automatisch`, untar the config archive there first so .env is back
before any container starts, `docker compose down -v`, which drops the old volumes,
`docker compose up -d postgres`, wait 30 seconds for healthy, pipe `gunzip -c` on the `.sql.gz`
into `docker compose exec -T postgres psql -U automatisch -d automatisch`, run that same psql
command with `-c "UPDATE flows SET active = false;"`, then `docker compose up -d`. That last
statement is the step people miss: a published flow's schedule lives in Redis, so a restored
database describes flows nothing runs; clearing the flag lets the user switch each back on, which
re-registers it. Restored without the matching `ENCRYPTION_KEY`, the database comes back with
every flow intact and every credential unreadable.

## 9. Updating later

New versions are listed at https://github.com/automatisch/automatisch/releases. Back up first,
then edit the image line in ~/selfhost/automatisch/compose.yml to the new tag and digest.

```bash
cd ~/selfhost/automatisch
docker compose pull
docker compose up -d
docker compose logs --tail 30 automatisch
```

Watch it until it settles, then re-run step 7's checks.

## 10. What will probably go wrong

I closed the lid, came back next morning, and found an empty executions page on a flow I had
published the night before. Nothing was broken. Docker Desktop had not restarted with the
session, so nothing was listening on 8171, and once it was, Automatisch pins every polling
trigger to a fifteen-minute cron without an enterprise licence, so the first run was another
quarter of an hour off. Turn on Docker Desktop's start-at-login setting, then after a reboot run
`cd ~/selfhost/automatisch && docker compose up -d` and look for `Workers are ready!`.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `API_URL` to this machine's LAN address and do not rebind 8171 to 0.0.0.0 so a
  phone or a webhook can reach it. That puts an engine holding every credential the user has
  connected onto every network they join.
- Do not configure SMTP, set `LICENSE_KEY`, or enable SAML, roles, templates or the public REST
  API under /api/v1. Those read files marked `.ee.`, on a separate licence.
- Do not connect a third-party app yet. Each connector needs its own developer registration.
