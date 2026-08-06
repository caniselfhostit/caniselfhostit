You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Coolify 4.1.2 and the PostgreSQL, Redis and realtime server it needs under
~/selfhost/coolify, answering at http://localhost:8115.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Coolify deploys by logging into the machine it manages over a remote login channel, and
this prompt does not open one into the user's own computer, so the dashboard runs here and the
server entry it makes stays unreachable. They get the interface and the catalogue to learn on.
Nothing deploys from here; if that is not what they wanted, stop.

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
distribution ID and codename print next, for step 2. Four containers want 2048 MB of RAM
available and 30 GB free on the home disk, and all four images publish amd64 and arm64. On macOS
and Windows that memory is the host's, and Docker Desktop takes its share out of it. If available
RAM is under 2048 MB or free disk under 30 GB, print both and stop.

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
mkdir -p ~/selfhost/coolify/backups
ls -la ~/selfhost/coolify
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: the account and
the projects are rows in PostgreSQL, which step 5 keeps in a Docker volume.

## 4. Secrets

Seven, all generated here: the instance id, the application key, the database and Redis
passwords, and three realtime credentials. Print none of them and keep them out of your summary.
Hex, because two travel inside connection strings.

```bash
umask 077
cat > ~/selfhost/coolify/.env <<EOF
APP_ID=$(openssl rand -hex 16)
APP_NAME=Coolify
AUTOUPDATE=false
APP_KEY=base64:$(openssl rand -base64 32)
DB_USERNAME=coolify
DB_DATABASE=coolify
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
PUSHER_APP_ID=$(openssl rand -hex 32)
PUSHER_APP_KEY=$(openssl rand -hex 32)
PUSHER_APP_SECRET=$(openssl rand -hex 32)
EOF
umask 022
chmod 640 ~/selfhost/coolify/.env
if [ "$(uname -s)" = "Linux" ]; then sudo chown "$(id -u)":9999 ~/selfhost/coolify/.env; fi
ls -l ~/selfhost/coolify/.env
```

Assert: mode `-rw-r-----`. Git Bash ships openssl, so these run the same on all three systems.
640 rather than 600 is deliberate: the container reads this file as uid 9999. On Windows those
mode bits are advisory and the real boundary is the user's own account.

## 5. compose.yml

```bash
cat > ~/selfhost/coolify/compose.yml <<'EOF'
# Coolify · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   manual install ..... https://coolify.io/docs/get-started/installation
#   ports and firewall . https://coolify.io/docs/knowledge-base/server/firewall
#   host connection .... https://coolify.io/docs/knowledge-base/server/openssh
#   proxy choices ...... https://coolify.io/docs/knowledge-base/server/proxies
#
# Four services on the computer you are sitting at, every path relative to
# ~/selfhost/coolify/ so one file works on macOS, Linux and Windows. PostgreSQL
# and Redis keep their data in named volumes, as upstream does, because both
# chown their data directory to a uid of their own choosing and a bind mount in
# a home directory cannot allow that on Windows. Digests read 2026-08-06.
#
# Read this first: here the dashboard runs and the server entry it makes for
# this computer stays unreachable, because the application reaches what it
# deploys to over a remote login channel this path does not open. Nothing
# deploys from here, which is why the storage directories the server file
# mounts are absent.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  coolify:
    image: ghcr.io/coollabsio/coolify:4.1.2@sha256:3a27ba5f7f98ff7763a0a4d6715ec36e564f9622eea8f492c46f90716ea2525f
    container_name: coolify
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    env_file: ./.env
    volumes:
      - ./.env:/var/www/html/.env:ro
    ports:
      - "127.0.0.1:8115:8080"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8080/api/health || exit 1"]
      interval: 10s
      retries: 30
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      soketi:
        condition: service_started

  postgres:
    image: postgres:15.18-alpine@sha256:3d0f7584ed7d04e27fa050d6683a74746608faf21f202be78460d679cc56461f
    container_name: coolify-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: coolify
    volumes:
      - coolify-db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coolify -d coolify"]
      interval: 10s
      retries: 30

  redis:
    image: redis:7.4.10-alpine@sha256:e7723ff73d963f5cc6d9c4643ea3d989527a402a319239054e9472a7fb9219a2
    container_name: coolify-redis
    restart: unless-stopped
    command: ["redis-server", "--save", "20", "1", "--requirepass", "${REDIS_PASSWORD}"]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    volumes:
      - coolify-redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" ping | grep -q PONG"]
      interval: 10s
      retries: 30

  soketi:
    image: ghcr.io/coollabsio/coolify-realtime:1.0.16@sha256:b5bb9d1c95d9b4ca59773b82d1e1a2bf4ccac5fbed33be19b9b3906574db3629
    container_name: coolify-realtime
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      SOKETI_DEFAULT_APP_ID: ${PUSHER_APP_ID}
      SOKETI_DEFAULT_APP_KEY: ${PUSHER_APP_KEY}
      SOKETI_DEFAULT_APP_SECRET: ${PUSHER_APP_SECRET}
    ports:
      - "127.0.0.1:6001:6001"
      - "127.0.0.1:6002:6002"

networks:
  default:
    name: coolify

volumes:
  coolify-db:
    name: coolify-db
  coolify-redis:
    name: coolify-redis
EOF
cd ~/selfhost/coolify && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Four services, three published ports, two named volumes.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no
hostname, so nothing to resolve. A certificate attests a public name and nothing here has one;
browsers treat http://localhost as a secure context anyway, so pages needing crypto still work.
Nothing is published beyond loopback, so no port needs closing: 8115, 6001 and 6002 bind to
127.0.0.1, not the user's phone, not a laptop on the same wifi, not anyone. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/coolify/compose.yml
```

Assert: `3`. PostgreSQL and Redis publish no host port, so 5432 and 6379 cannot appear.

## 7. Start and verify

It migrates its own database on the way up, so a cold start takes minutes.

```bash
cd ~/selfhost/coolify
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8115/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8115/api/health; echo
curl -sSL -o /dev/null -w '%{url_effective}\n' http://localhost:8115/
curl -sSL http://localhost:8115/register | grep -c 'Create your account'
docker compose ps
```

Assert all five, printing what you got. The loop ends on `200`. `/api/health` answers the single
word `OK`. The root lands on `http://localhost:8115/register`, where an instance with no users
sends everyone. The grep prints at least `1`: that screen carries `Coolify` above the line
`Create your account`. `ps` shows four containers up. On any miss stop, run
`docker compose logs --tail 40 coolify`, and name the cause: an unhealthy database is step 4 with
an empty `DB_PASSWORD`, and `port is already allocated` means something else holds 8115, 6001 or
6002. A container is not success.

STOP: tell the user to open http://localhost:8115 and create their account there. It is the only
moment it can be made and no mail server here can reset it, so have them save the password first.
Do not continue until they confirm.

```bash
curl -sSL -o /dev/null -w '%{url_effective}\n' http://localhost:8115/register
```

Assert: `http://localhost:8115/login`. Registration closes once the first user exists. Tell the
user what they will see next: a server named `localhost`, marked unreachable. That is step 1's
warning on screen, not a fault to chase.

## 8. First backup and restore

Two artifacts: the database holds the account and every project record, the archive the two
files that rebuild the service.

```bash
cd ~/selfhost/coolify
docker compose exec -T postgres pg_dump -U coolify -d coolify | gzip > ~/selfhost/coolify/backups/coolify-db-$(date +%F).sql.gz
tar -C ~/selfhost/coolify -czf ~/selfhost/coolify/backups/coolify-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/coolify/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing goes down: `pg_dump` snapshots
a running database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy both there with `cp`; in Git Bash a Windows
drive is `/d/Backups`. Assert: the user confirms both are listed there, or say plainly that this
install has no backup.

To restore, in this order. `cd ~/selfhost/coolify` and untar the config archive there first, so
compose.yml and .env are back before any container starts: PostgreSQL takes `DB_PASSWORD` from
.env the moment it initialises an empty volume. Then `docker compose down -v`, the one place
`-v` belongs, `docker compose up -d postgres`, wait about 30 seconds for healthy, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U coolify -d coolify`,
then `docker compose up -d`, then log in once to prove it. Those rows are encrypted with
`APP_KEY` from that `.env`, so the two files travel together or neither is a backup.

## 9. Updating later

Versions are listed at https://github.com/coollabsio/coolify/releases, and the realtime image
pairing with each is in `versions.json` at that tag. Back up first, then edit the two image
lines in compose.yml:

```bash
cd ~/selfhost/coolify
docker compose pull
docker compose up -d
docker compose logs --tail 40 coolify
```

Watch that log settle, then re-run step 7's check before calling it done.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8115 and got a connection refused that reads
like a lost install. It was not: Docker Desktop had not started with the session, so nothing was
listening on 8115, and `restart: unless-stopped` only acts once the Docker daemon is up. Turn on
its start-at-login setting, then run `docker compose up -d` in ~/selfhost/coolify after a reboot
before concluding anything is broken.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not open a remote login service on this computer, and do not add this machine as a server
  in the dashboard. That hands a container a key to the user's own account, a trade worth making
  on a rented box and not on this one.
- Do not select Traefik or Caddy as a proxy in the dashboard, do not configure SMTP, and do not
  connect a GitHub App. All three are work handed to an install that cannot deploy.
