You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Twenty 2.30.1 under ~/selfhost/twenty, answering at http://localhost:8183.

## 1. Preflight

Say this to the user before step 2 runs: it decides whether they want this install. A CRM is usually shared, and this one answers at http://localhost:8183: a colleague or their
own phone gets a connection error, and the worker runs only while this machine is awake. What is
left is a private customer database with a real data model and an API.

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
distribution ID and codename print next, for step 2. Twenty needs 4096 MB of RAM available and
20 GB free on the home disk, and both architectures are published. On macOS and Windows that
figure is the host's, and Docker Desktop takes its share out of it. If either floor is missed,
print both and stop.

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
mkdir -p ~/selfhost/twenty/storage ~/selfhost/twenty/backups
if [ "$(uname -s)" = "Linux" ]; then sudo chown -R 1000:1000 ~/selfhost/twenty/storage; fi
ls -la ~/selfhost/twenty
```

Assert: `ls -la` shows `storage` and `backups`. There is no database folder: step 5 keeps
PostgreSQL in a volume Docker manages, because that image chowns its directory to a uid a home
bind mount cannot grant on Windows. `storage` stays a bind mount, handed on Linux to uid 1000,
which the image runs as.

## 4. Secrets

Three: the key that encrypts stored secrets at rest, the legacy application secret the token code
still reaches for, and the PostgreSQL password. Generate all three here, print none of them, keep
them out of your summary and any log line. Git Bash ships openssl. The database password is
hex because upstream asks for no special characters in the connection string.

```bash
umask 077
cat > ~/selfhost/twenty/.env <<EOF
SERVER_URL=http://localhost:8183
APP_SECRET=$(openssl rand -base64 32)
ENCRYPTION_KEY=$(openssl rand -base64 32)
PG_DATABASE_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/twenty/.env
umask 022
ls -l ~/selfhost/twenty/.env
```

Assert: mode `-rw-------`. Upstream says losing `ENCRYPTION_KEY` loses access to every secret in
the database, so tell the user to read it with `grep ENCRYPTION_KEY ~/selfhost/twenty/.env` today.
On Windows mode bits are advisory; the boundary is their own account.

## 5. compose.yml

```bash
cat > ~/selfhost/twenty/compose.yml <<'EOF'
# Twenty · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation and upstream's own compose file:
#   docker compose ..... https://docs.twenty.com/developers/self-host/capabilities/docker-compose
#
# The same four services upstream's own file runs, on the computer the reader is
# sitting at. Paths are relative to ~/selfhost/twenty/, so one file works on all
# three systems. The database is a named volume because PostgreSQL chowns that
# directory to a uid a home bind mount cannot grant on Windows. Digests read
# from the registry on 2026-08-12.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: twenty-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: default
      POSTGRES_USER: twenty
      POSTGRES_PASSWORD: ${PG_DATABASE_PASSWORD}
    volumes:
      - twenty-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U twenty -d default"]
      interval: 10s
      retries: 12

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: twenty-redis
    restart: unless-stopped
    command: ["--maxmemory-policy", "noeviction"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  server:
    image: twentycrm/twenty:v2.30.1@sha256:36049a73f0d2e25c059007ccb452cf183b02fd57cb107afee7d959879639fa97
    container_name: twenty-server
    restart: unless-stopped
    env_file: ./.env
    environment:
      NODE_PORT: 3000
      PG_DATABASE_URL: postgres://twenty:${PG_DATABASE_PASSWORD}@db:5432/default
      REDIS_URL: redis://redis:6379
      STORAGE_TYPE: local
    volumes:
      - ./storage:/app/packages/twenty-server/.local-storage
    healthcheck:
      test: ["CMD", "curl", "--fail", "http://localhost:3000/healthz"]
      interval: 10s
      timeout: 5s
      retries: 30
    ports:
      - "127.0.0.1:8183:3000"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  worker:
    image: twentycrm/twenty:v2.30.1@sha256:36049a73f0d2e25c059007ccb452cf183b02fd57cb107afee7d959879639fa97
    container_name: twenty-worker
    restart: unless-stopped
    command: ["yarn", "worker:prod"]
    env_file: ./.env
    environment:
      PG_DATABASE_URL: postgres://twenty:${PG_DATABASE_PASSWORD}@db:5432/default
      REDIS_URL: redis://redis:6379
      STORAGE_TYPE: local
      DISABLE_DB_MIGRATIONS: "true"
      DISABLE_CRON_JOBS_REGISTRATION: "true"
    volumes:
      - ./storage:/app/packages/twenty-server/.local-storage
    depends_on:
      db:
        condition: service_healthy
      server:
        condition: service_healthy

volumes:
  twenty-pgdata:
EOF
cd ~/selfhost/twenty && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK` prints. Compose reads ./.env here for `${PG_DATABASE_PASSWORD}`, so cd
in first.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, and a certificate attests a public name nothing here has. Browsers treat
http://localhost as a secure context anyway, which is what upstream wants. 8183 is bound to
127.0.0.1: not the user's phone, not a laptop on the wifi, not the internet:

```bash
grep -c '"127.0.0.1:' ~/selfhost/twenty/compose.yml
```

Assert: that prints `1`, the published-port entry `- "127.0.0.1:8183:3000"`. A `0.0.0.0:8183` or
a bare `8183:3000` means the file was edited: put the `127.0.0.1:` prefix back first.

## 7. Start and verify

The server runs the schema setup and every migration before answering. Use the loop.

```bash
cd ~/selfhost/twenty
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8183/healthz); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8183/healthz; echo
curl -sSL http://localhost:8183/ | grep -c '<title>Twenty</title>'
curl -sS http://localhost:8183/client-config | grep -o '"isMultiWorkspaceEnabled":[a-z]*'
docker compose ps --format '{{.Service}} {{.State}}'
```

Assert all five and print what you received for each. The loop ends on `200`. The health body
contains `"status":"ok"`. The third prints a number above `0`, the title the served page carries.
The fourth prints `"isMultiWorkspaceEnabled":false`. The last prints four lines, `db`, `redis`,
`server` and `worker`, each `running`. If any misses, stop, run
`docker compose logs --tail 60 server` and `docker compose logs --tail 20 db` and name the cause:
a database that never reports healthy holds the rest in `depends_on`, and
`port is already allocated` means something else has 8183.

Twenty ships no setup wizard and no seeded administrator: the first person to finish the
workspace form becomes the administrator, and upstream refuses every later signup.

STOP: tell the user to open http://localhost:8183, create their account, keep going until the
workspace exists and the records screen has loaded, and save that password in their password
manager. Do not continue until they confirm the records screen.

Once they confirm, ask the signup mutation for an account nobody owns:

```bash
curl -sS -X POST http://localhost:8183/graphql -H 'content-type: application/json' --data '{"query":"mutation Probe($e: String!, $p: String!) { signUp(email: $e, password: $p) { tokens { refreshToken { token } } } }","variables":{"e":"closure-probe@example.com","p":"probe-not-a-login"}}' -o /tmp/twenty-signup-probe.json
cat /tmp/twenty-signup-probe.json; echo
grep -c SIGNUP_DISABLED /tmp/twenty-signup-probe.json
```

Assert: the body carries `"subCode":"SIGNUP_DISABLED"` and no token, and the grep prints `1`. If
it prints `0`, a `refreshToken` in the body means an account was created, because the user stopped
before the workspace existed: send them back, then probe again.

## 8. First backup and restore

Two artifacts: the database with every record and account, and an archive with the attachments
and the two files that rebuild it.

```bash
cd ~/selfhost/twenty
docker compose exec -T db pg_dump -U twenty -d default | gzip > ~/selfhost/twenty/backups/twenty-db-$(date +%F).sql.gz
tar -C ~/selfhost/twenty -czf ~/selfhost/twenty/backups/twenty-files-$(date +%F).tar.gz compose.yml .env storage
ls -lh ~/selfhost/twenty/backups/
```

Assert: both exist, are non-empty, and print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

Both sit on the same disk as the data, and on a laptop the disk and the machine fail together.
Ask the user for a destination that leaves this computer, a sync folder or a USB stick, and copy
both there with `cp`. In Git Bash a Windows drive is `/d/Backups`, not `D:\Backups`. Assert: they
confirm both filenames are there, or say plainly there is no backup.

To restore: `cd ~/selfhost/twenty`; untar the archive there first, so `.env` is back before
anything starts, because PostgreSQL takes its password from it the moment it initialises an empty
volume; `docker compose down -v`, the one place `-v` belongs; then `docker compose up -d db`,
wait about 40 seconds for healthy, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U twenty -d default`, and `docker compose up -d`. On Linux run
step 3's `chown` line again after the untar. Both halves are needed: `ENCRYPTION_KEY` decrypts
the secrets in those rows.

## 9. Updating later

New versions are listed at https://github.com/twentyhq/twenty/releases. The release tag carries a
`twenty/` prefix and the image tag does not. Back up first, then edit both image lines in
~/selfhost/twenty/compose.yml: server and worker must never run different builds.

```bash
cd ~/selfhost/twenty
docker compose pull
docker compose up -d
docker compose logs --tail 40 server
```

The server migrates on the way up. Watch that log until it settles, then re-run step 7.

## 10. What will probably go wrong

The first boot looks like a hang, and on a laptop it is slower still. I watched
`docker compose ps` report `server` as `starting` for six minutes while Docker Desktop unpacked a
gigabyte of image and then ran every migration before opening the port. Nothing was wrong. Watch
`docker compose logs -f server`, not the browser. After a reboot nothing answers 8183 until
Docker Desktop runs again: turn on its start-at-login setting.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8183 to 0.0.0.0 for a phone on the wifi. `SERVER_URL` carries `localhost`, so the
  app would load on an address it does not believe in.
- Do not configure SMTP, Google or Microsoft authentication, or calendar and messaging sync.
- Do not set `LOGIC_FUNCTION_TYPE` or `CODE_INTERPRETER_TYPE` to `LOCAL`: that driver runs
  submitted code here with no sandbox, which is why upstream disables it outside dev.
