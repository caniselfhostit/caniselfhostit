You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Formbricks 5.3.0, with the PostgreSQL, Valkey, Hub and Cube it needs, under
~/selfhost/formbricks, answering at http://localhost:8110.

## 1. Preflight

Say this first: every link this makes begins with http://localhost:8110, which means "this
computer" wherever it is read, so one sent to anybody else resolves to nothing.

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
distribution ID prints too, for step 2. This stack needs 4096 MB of RAM available and 20 GB
free, upstream's own Helm limits added up, and both architectures are published. On macOS and
Windows that number is the host's and Docker Desktop takes its share. Under either floor, print
both and stop.

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

Cube reads two files upstream ships in their repository, not their image. Fetch both at the
pinned tag and verify them first.

```bash
mkdir -p ~/selfhost/formbricks/backups ~/selfhost/formbricks/cube/schema
cd ~/selfhost/formbricks/cube
for f in cube.js schema/FeedbackRecords.js; do curl -fsSL -o "$f" "https://raw.githubusercontent.com/formbricks/formbricks/5.3.0/docker/cube/$f"; done
cat > SHA256SUMS <<'EOF'
723eea0f581200a686f854ff47b38f2e92bbfe5d802338049afaa061f154a335  cube.js
c3322a3739ee1cc57224139f502395a20dcbe4dd71e331be41d687ffdfe140f8  schema/FeedbackRecords.js
EOF
if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi
ls -la ~/selfhost/formbricks
```

Assert: two lines ending `OK`; print both. macOS ships `shasum`, not `sha256sum`; that is what
the guard is for. On `FAILED`, stop: those are not the bytes recorded on 2026-08-06. `ls -la`
shows `backups` and `cube`, owned by the user.

## 4. Secrets

Six: the PostgreSQL password and five keys the app requires. Generate all six here, print none,
and keep them out of your summary and every log line. Git Bash ships openssl.

```bash
umask 077
cat > ~/selfhost/formbricks/.env <<EOF
WEBAPP_URL=http://localhost:8110
NEXTAUTH_URL=http://localhost:8110
DB_PASSWORD=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
CRON_SECRET=$(openssl rand -hex 32)
HUB_API_KEY=$(openssl rand -hex 32)
CUBEJS_API_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/formbricks/.env
umask 022
ls -l ~/selfhost/formbricks/.env
```

Assert: mode `-rw-------`. On Windows those bits are advisory and the real boundary is the
user's own account. `ENCRYPTION_KEY` encrypts two-factor secrets and single-use survey links, so
a database restored without it is unreadable.

## 5. compose.yml

```bash
cat > ~/selfhost/formbricks/compose.yml <<'EOF'
# Formbricks · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   compose setup ....... https://formbricks.com/docs/self-hosting/setup/docker
#   variable reference .. https://formbricks.com/docs/self-hosting/configuration/environment-variables
#
# Seven services: five that stay up, two migration jobs that run in order and
# exit. Paths are relative to ~/selfhost/formbricks/. PostgreSQL and Valkey get
# named volumes rather than binds because each chowns its own data directory to
# a uid Docker Desktop cannot grant on a Windows home bind.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.
name: formbricks

services:
  postgres:
    image: pgvector/pgvector:0.8.6-pg18@sha256:691673308c99d2161ba298736f3147f1f22d79de2fb7ec93ae9b4afcab870b62
    restart: unless-stopped
    environment:
      POSTGRES_DB: formbricks
      POSTGRES_USER: formbricks
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - formbricks-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U formbricks -d formbricks"]
      interval: 10s
      retries: 30

  redis:
    image: valkey/valkey:9.0.5-alpine@sha256:0cb61366757e2bcd26500b4e8bb63cbd7117610e3e4f05aacb3c812511da7632
    restart: unless-stopped
    command: ["valkey-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - formbricks-redisdata:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      retries: 30

  formbricks-migrate:
    image: ghcr.io/formbricks/formbricks:5.3.0@sha256:d79dba3668a359b63d984ac39b19a58fb6746b3aed57fd890b9f2f6f372210e6
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?schema=public
    command: ["node", "packages/database/dist/scripts/apply-migrations.js"]
    depends_on:
      postgres:
        condition: service_healthy

  hub-migrate:
    image: ghcr.io/formbricks/hub:0.8.3@sha256:4dc0c4f26cf999b3bf4a26d7b09634fc65ae23cbb30c9ad82042da019d231458
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?sslmode=disable
    entrypoint: ["sh", "-c"]
    command: ['/usr/local/bin/goose -dir /app/migrations postgres "$$DATABASE_URL" up && /usr/local/bin/river migrate-up --database-url "$$DATABASE_URL"']
    depends_on:
      formbricks-migrate:
        condition: service_completed_successfully

  hub:
    image: ghcr.io/formbricks/hub:0.8.3@sha256:4dc0c4f26cf999b3bf4a26d7b09634fc65ae23cbb30c9ad82042da019d231458
    restart: unless-stopped
    environment:
      API_KEY: ${HUB_API_KEY}
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?sslmode=disable
    depends_on:
      hub-migrate:
        condition: service_completed_successfully

  cube:
    image: cubejs/cube:v1.6.6@sha256:746a381c5deb1f33500c84bed357ebe68aa08acc5030939f9e9efd35796d368c
    restart: unless-stopped
    environment:
      CUBEJS_DB_TYPE: postgres
      CUBEJS_DB_HOST: postgres
      CUBEJS_DB_NAME: formbricks
      CUBEJS_DB_USER: formbricks
      CUBEJS_DB_PASS: ${DB_PASSWORD}
      CUBEJS_API_SECRET: ${CUBEJS_API_SECRET}
      CUBEJS_JWT_ISSUER: formbricks-web
      CUBEJS_JWT_AUDIENCE: formbricks-cube
      CUBEJS_DEFAULT_API_SCOPES: meta,data
      CUBEJS_EXTERNAL_DEFAULT: "false"
      CUBEJS_CACHE_AND_QUEUE_DRIVER: memory
    volumes:
      - ./cube/cube.js:/cube/conf/cube.js:ro
      - ./cube/schema:/cube/conf/model:ro
    healthcheck:
      test: ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:4000/readyz', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]
      interval: 10s
      retries: 18
      start_period: 40s
    depends_on:
      hub-migrate:
        condition: service_completed_successfully

  formbricks:
    image: ghcr.io/formbricks/formbricks:5.3.0@sha256:d79dba3668a359b63d984ac39b19a58fb6746b3aed57fd890b9f2f6f372210e6
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgresql://formbricks:${DB_PASSWORD}@postgres:5432/formbricks?schema=public
      REDIS_URL: redis://redis:6379
      HUB_API_URL: http://hub:8080
      CUBEJS_API_URL: http://cube:4000
      EMAIL_VERIFICATION_DISABLED: "1"
      PASSWORD_RESET_DISABLED: ${PASSWORD_RESET_DISABLED:-1}
      SKIP_STARTUP_MIGRATION: "true"
    ports:
      - "127.0.0.1:8110:3000"
    depends_on:
      formbricks-migrate:
        condition: service_completed_successfully
      redis:
        condition: service_healthy
      cube:
        condition: service_healthy
      hub:
        condition: service_started

volumes:
  formbricks-pgdata:
  formbricks-redisdata:
EOF
cd ~/selfhost/formbricks && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Nothing here is optional: Hub and Cube are baseline in 5, and the app
needs a Redis URL to start.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, and a certificate attests a public name that nothing here has; browsers treat
http://localhost as a secure context anyway, so pages needing crypto still work. 8110 binds to
127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on the internet. That
is the trade, and the point of this path. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/formbricks/compose.yml
```

Assert: one line, `- "127.0.0.1:8110:3000"`. The other four publish no host port at all.

## 7. Start and verify

The migration jobs run and exit first, then Cube must be healthy before the web container
starts. On a cold pull that takes minutes.

```bash
cd ~/selfhost/formbricks
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8110/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8110/health
curl -sSL -o /dev/null -w '%{url_effective}\n' http://localhost:8110/
curl -sSL http://localhost:8110/ | grep -c 'Welcome to Formbricks'
docker compose ps -a
```

Assert all five, printing each: the loop ends on `200`; health returns `{"status":"ok"}`; the
redirect lands on `http://localhost:8110/setup/intro`; the grep prints at least `1`, that screen
carrying the heading `Welcome to Formbricks!` above a `Get started` button; `ps -a` shows both
migration containers `exited (0)` and the other five up. If any misses, stop, run
`docker compose logs --tail 40 formbricks cube hub-migrate` and name the step to blame:
hub-migrate exiting non-zero is step 4 and an empty `DB_PASSWORD`; cube unhealthy is step 3 and
a failed checksum; `port is already allocated` is something else on 8110. A running container
is not success.

STOP: tell the user to open http://localhost:8110, click `Get started`, create their
administrator account and organization, and wait. Do not continue until they confirm. It is the
only moment that account can be made, signup closes afterwards, and with no SMTP there is no
reset mail, so have them save the password first.

Then prove the door shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8110/setup/intro
curl -sSL -o /dev/null -w '%{url_effective}\n' http://localhost:8110/
```

Assert: `404`, then `http://localhost:8110/auth/login`. The wizard answers only while the user
table is empty, and both must pass before you report success.

## 8. First backup and restore

The database holds every survey, response and account; the config archive holds what rebuilds
the service around it, `ENCRYPTION_KEY` included.

```bash
cd ~/selfhost/formbricks
docker compose exec -T postgres pg_dump -U formbricks -d formbricks | gzip > backups/formbricks-db-$(date +%F).sql.gz
tar -czf backups/formbricks-config-$(date +%F).tar.gz compose.yml .env cube
ls -lh backups/
```

Assert: both exist, both non-empty, print both sizes. Nothing stops: `pg_dump` snapshots a
running database consistently. Valkey holds cache and jobs, not data.

Both archives are on the same disk as the data, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a sync folder or a USB
stick, and copy both there with `cp`; in Git Bash a Windows drive is `/d/Backups`, not
`D:\Backups`. Assert: the user confirms both filenames are there, or say plainly that there is
no backup.

To restore: untar the config archive into ~/selfhost/formbricks first, so .env is back before
any container starts, because PostgreSQL reads `DB_PASSWORD` from it the moment it initialises
an empty volume. Then `docker compose down -v`, the one place `-v` belongs because it drops the
old volume on purpose, `docker compose up -d postgres`, wait 30 seconds, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U formbricks -d formbricks`, then
`docker compose up -d`. Without that `.env` the rows come back unreadable.

## 9. Updating later

Releases are at https://github.com/formbricks/formbricks/releases; the Hub and Cube versions
paired with each are in `charts/formbricks/values.yaml` in that tag. Back up first, then edit
the image lines:

```bash
cd ~/selfhost/formbricks
docker compose pull
docker compose up -d
docker compose logs --tail 40 formbricks-migrate hub-migrate formbricks
```

Both jobs rerun on every start, so watch them exit 0, then re-run step 7's check.

## 10. What will probably go wrong

Memory. On my Mac the app container came up, died, came up and died again, and the log said
nothing useful, because the kernel had killed it rather than the process failing. Docker Desktop
runs everything in a virtual machine with its own memory ceiling, and the default is under what
five services want. Open its Settings, then Resources, give the machine 6 GB, apply, restart,
then `docker compose up -d` again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not point `WEBAPP_URL` at a LAN address or rebind 8110 to 0.0.0.0 so a phone can reach it.
- Do not configure SMTP, S3 or RustFS storage, enable the `qwen` or `taxonomy` profiles, or set
  `ENTERPRISE_LICENSE_KEY`. Mail is off by upstream's default, storage is another service, an
  AI profile wants a GPU, and the key is the paid tier.
