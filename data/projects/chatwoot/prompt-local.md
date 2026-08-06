You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Chatwoot 4.16.2, community edition, with the PostgreSQL and Redis it needs, under
~/selfhost/chatwoot, answering at http://localhost:8102.

## 1. Preflight

Say this before step 2 runs; it decides whether they want this install at all. The widget
Chatwoot generates loads its script from http://localhost:8102, so no visitor on another machine
can open it. What is left is the dashboard, the help center and the API: a place to learn the
tool, not a chat customers can reach.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash; on Linux the ID
and codename print next, for step 2. Chatwoot needs 4096 MB of RAM available and 20 GB free on
the home disk, upstream's minimum; all three images publish amd64 and arm64. On macOS and Windows
raise Docker Desktop's own memory allocation to at least 4 GB first. If available RAM is under
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
mkdir -p ~/selfhost/chatwoot/storage ~/selfhost/chatwoot/redis ~/selfhost/chatwoot/backups
ls -la ~/selfhost/chatwoot
```

Assert: `ls -la` shows `storage`, `redis` and `backups`, owned by the user. Nothing here needs a
chown: the containers run as root inside themselves and write into folders the user owns. The
database gets a Docker-managed volume instead, because that image picks its own uid.

## 4. Secrets

Three secrets: the Rails key that signs cookies and sessions, the PostgreSQL password and the
Redis password. Generate all three here, print none, and keep them out of your summary and logs.

```bash
umask 077
cat > ~/selfhost/chatwoot/.env <<EOF
FRONTEND_URL=http://localhost:8102
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/chatwoot/.env
umask 022
ls -l ~/selfhost/chatwoot/.env
```

Assert: mode `-rw-------`. Git Bash ships openssl, and no human logs in with these values. On
Windows the mode bits are advisory: NTFS ignores them, and the user's account is the boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/chatwoot/compose.yml <<'EOF'
# Chatwoot · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker deployment .. https://developers.chatwoot.com/self-hosted/deployment/docker
#   variable reference . https://developers.chatwoot.com/self-hosted/configuration/environment-variables
#   requirements ....... https://developers.chatwoot.com/self-hosted/deployment/requirements
#
# Four services, every path relative to ~/selfhost/chatwoot/, so one file works
# on macOS, Linux and Windows. The database is a named volume because the
# PostgreSQL image chowns its data directory to its own uid, which a
# home-directory bind mount cannot allow on Windows; that image is pgvector's
# because Chatwoot's schema turns on `vector`; -ce is the community edition,
# built with enterprise/ deleted. Digests read 2026-08-06, amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# Rails and Sidekiq share an image and an environment; compose ignores x- keys.
x-chatwoot: &chatwoot
  image: chatwoot/chatwoot:v4.16.2-ce@sha256:7ee85a208147a86188ffc0e7fafafd2e1c0403b4ad6aea9e31f566662cce1d2f
  restart: unless-stopped
  env_file: ./.env
  environment:
    RAILS_ENV: production
    NODE_ENV: production
    INSTALLATION_ENV: docker
    POSTGRES_HOST: postgres
    POSTGRES_USERNAME: chatwoot
    POSTGRES_DATABASE: chatwoot_production
    REDIS_URL: redis://redis:6379
    # Signup stays shut: one account, made once through the onboarding screen.
    ENABLE_ACCOUNT_SIGNUP: "false"
    ACTIVE_STORAGE_SERVICE: local
  volumes:
    - ./storage:/app/storage
  depends_on:
    postgres:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg16@sha256:a36250871de0833b8757561c72f2477ef1ddd1101afa4e617fb552e0de514c6b
    container_name: chatwoot-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: chatwoot_production
      POSTGRES_USER: chatwoot
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - chatwoot-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chatwoot -d chatwoot_production"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: chatwoot-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    # Doubled dollar: compose leaves it, the container's own shell expands it.
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass $$REDIS_PASSWORD"]
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli --no-auth-warning -a $$REDIS_PASSWORD ping | grep -q PONG"]
      interval: 10s
      retries: 12

  rails:
    <<: *chatwoot
    container_name: chatwoot-rails
    entrypoint: docker/entrypoints/rails.sh
    command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    ports:
      # Loopback only: no other device on the wifi can reach 8102.
      - "127.0.0.1:8102:3000"

  sidekiq:
    <<: *chatwoot
    container_name: chatwoot-sidekiq
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]

volumes:
  chatwoot-pgdata:
EOF
cd ~/selfhost/chatwoot && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. Nothing here has a public name to certify, and browsers treat http://localhost as a
  secure context anyway, so pages needing crypto still work.
- No firewall rule. Nothing is published beyond loopback.

8102 is bound to 127.0.0.1: not the user's phone, not a laptop on the wifi, not the internet.
For an inbox of other people's messages that is the trade. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/chatwoot/compose.yml
```

Assert: one line, `- "127.0.0.1:8102:3000"`. PostgreSQL and Redis publish no host port.

## 7. Start and verify

Prepare the database first. Upstream documents `rails db:chatwoot_prepare` as the task that loads
the schema and seeds the onboarding flag, then migrates later.

```bash
cd ~/selfhost/chatwoot
docker compose pull
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8102/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8102/health
curl -sS http://localhost:8102/api
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8102/api/v1/accounts
curl -sS http://localhost:8102/installation/onboarding | grep -o 'Howdy, Welcome to Chatwoot'
```

Assert all five, printing what you received for each. The loop ends on `200`; the health response
is exactly `{"status":"woot"}`; `/api` contains `"queue_services":"ok"` and
`"data_services":"ok"`, Chatwoot reporting that it reached Redis and PostgreSQL itself; the
unauthenticated POST prints `404`, because signup is off, the security assert here; the last
command prints the onboarding heading. If any misses, stop, run
`docker compose logs --tail 40 rails` and name the cause: `"data_services":"failing"` is step 4
and a `.env` missing its password lines, `port is already allocated` is something else on 8102,
a log still eager-loading wants time. A running container is not success.

The first screen at http://localhost:8102 shows the heading `Howdy, Welcome to Chatwoot`, a
waving emoji after it, above a form asking for a name, a company, a work email and a password.

STOP: tell the user to open http://localhost:8102 and create their administrator account there,
and wait. Do not continue until they confirm. That form runs once, and this install has no mail,
so tell them to put the password in their password manager as they type it.

Once they confirm, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8102/installation/onboarding
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8102/
```

Assert: the first prints `302`, the onboarding screen refusing, and the second prints `200`.

## 8. First backup and restore

Two artifacts: a dump of every conversation and contact, and a config archive of the rest.

```bash
cd ~/selfhost/chatwoot
docker compose exec -T postgres pg_dump -U chatwoot -d chatwoot_production | gzip > ~/selfhost/chatwoot/backups/chatwoot-db-$(date +%F).sql.gz
tar -C ~/selfhost/chatwoot -czf ~/selfhost/chatwoot/backups/chatwoot-config-$(date +%F).tar.gz compose.yml .env storage
ls -lh ~/selfhost/chatwoot/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database. Redis holds queues and caches, so it is skipped.

Both archives sit on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination off this computer, a sync folder or a USB stick, and
copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`. Assert: they confirm both
filenames are there, or say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/chatwoot`, untar the config archive there first so
compose.yml and .env are back before any container starts: PostgreSQL takes its password from
.env when it initialises an empty volume, and the Rails key there is what makes restored sessions
verify. Then `docker compose down -v`, the one place `-v` belongs, `docker compose up -d postgres`,
wait 30 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U chatwoot -d chatwoot_production`, then
`docker compose up -d`. That is the whole disaster plan.

## 9. Updating later

New versions are at https://github.com/chatwoot/chatwoot/releases; keep the `-ce` suffix. Back up
first, then edit the image line in ~/selfhost/chatwoot/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/chatwoot
docker compose pull
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
docker compose logs --tail 30 rails
```

That prepare run migrates the database the new image inherited. Then re-run step 7's checks.

## 10. What will probably go wrong

I closed the laptop lid with a conversation open, came back an hour later, and the dashboard sat
there showing nothing new and no error. Nothing was broken: the machine had slept, Docker Desktop
with it, and Sidekiq had not been running to deliver anything. The same happens after a reboot,
because `restart: unless-stopped` acts only once the Docker daemon is up. Turn on Docker
Desktop's start-at-login, and run `cd ~/selfhost/chatwoot && docker compose up -d` after one.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not configure SMTP, and do not add a Facebook, Instagram, WhatsApp or email channel: each
  needs mail or a webhook URL the provider can reach, and nothing here has either.
- Do not set `ENABLE_ACCOUNT_SIGNUP` to true. Step 7 asserts that endpoint answers 404.
