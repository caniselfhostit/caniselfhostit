You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Windmill 1.789.0 under ~/selfhost/windmill, answering at http://localhost:8193.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install.
A webhook trigger is a URL you hand to Stripe or GitHub to call back, and here every URL
Windmill prints starts with http://localhost:8193, which resolves on this computer only. The
rest works in full: scripts in Python, TypeScript, Go, Bash and SQL, flows, schedules and the
app builder, while this machine is awake.

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

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. Windmill
needs 4096 MB of RAM available and 30 GB free on the home disk, and publishes amd64 and
arm64. The floor is not padding: one image carries Python, Bun, Deno, Go, PHP, Java, Ruby,
.NET and PowerShell. On macOS and Windows the figure above is the host's, so raise Docker
Desktop's memory limit to 4 GB first. If RAM is under 4096 MB or disk under 30 GB, print
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

```bash
mkdir -p ~/selfhost/windmill/backups
ls -la ~/selfhost/windmill
```

Assert: `ls -la` shows `backups`, the only directory this install makes. The database, the
language caches and the spilled logs live in named volumes rather than folders you can open:
the database chowns its data directory to a uid Docker Desktop cannot grant on a home folder
under Windows, and the cache arrives filled. No `chown`: the image runs as root.

## 4. Secrets

Two secrets: the PostgreSQL password, and the one that replaces Windmill's seeded superadmin
in step 7. Generate both here. Do not print either, repeat them in your summary, or log them.
Hex, not base64: one rides a connection string, the other JSON.

```bash
umask 077
cat > ~/selfhost/windmill/.env <<EOF
DB_PASSWORD=$(openssl rand -hex 32)
WM_ADMIN_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/windmill/.env
umask 022
ls -l ~/selfhost/windmill/.env
```

Assert: the file exists at mode `-rw-------`; Git Bash ships openssl, so this works on all
three systems. On Windows the mode bits are advisory and the real boundary is the user's own
account. No service uses `env_file`, so `WM_ADMIN_PASSWORD` never enters a container, which
matters because a job reads its worker's environment.

## 5. compose.yml

```bash
cat > ~/selfhost/windmill/compose.yml <<'EOF'
# Windmill · the deterministic fallback for the local path. Authored by
# caniselfhostit from https://github.com/windmill-labs/windmill/tree/v1.789.0
# and https://www.windmill.dev/docs/advanced/security_isolation
#
# BASE_URL is http://localhost:8193, so every link this instance prints
# resolves here and nowhere else. PostgreSQL and the Windmill cache are named
# volumes, not bind mounts: the database image chowns its data directory to a
# uid Docker Desktop cannot grant on a Windows home folder, and the cache
# arrives from the image already filled. One worker, no windmill-extra, no
# indexer, no `privileged: true`, for the reasons in the server file. Digests
# read on 2026-08-14; amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

# json-file does not rotate on its own; a busy worker fills a small disk.
x-logging: &wm-logging
  driver: json-file
  options:
    max-size: 20m
    max-file: "10"

services:
  db:
    image: postgres:16.15-alpine@sha256:ab5c955e9e57ae9879d4411ab49a912be9d162455676f7bf56e951b11ac73785
    container_name: windmill-db
    restart: unless-stopped
    shm_size: 1g
    environment:
      POSTGRES_DB: windmill
      POSTGRES_USER: windmill
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - windmill_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U windmill -d windmill"]
      interval: 10s
      retries: 12
    # No `ports:`: 5432 is reachable only from the other containers.

  windmill_server:
    image: ghcr.io/windmill-labs/windmill:1.789.0@sha256:de85c0d6960e8f339a93e5d62c04fb3a77bd53699f1d3abc0081bdb32f97fe5b
    container_name: windmill-server
    restart: unless-stopped
    environment:
      MODE: server
      DATABASE_URL: postgres://windmill:${DB_PASSWORD}@db:5432/windmill
      # No TLS and no hostname, so every link says http://localhost:8193.
      BASE_URL: http://localhost:8193
    volumes:
      # Job logs spill here, so this volume is shared with the worker.
      - windmill_logs:/tmp/windmill/logs
    ports:
      # Loopback only: no other device on the wifi reaches 8193.
      - "127.0.0.1:8193:8000"
    depends_on:
      db:
        condition: service_healthy
    logging: *wm-logging

  windmill_worker:
    image: ghcr.io/windmill-labs/windmill:1.789.0@sha256:de85c0d6960e8f339a93e5d62c04fb3a77bd53699f1d3abc0081bdb32f97fe5b
    container_name: windmill-worker
    restart: unless-stopped
    environment:
      MODE: worker
      WORKER_GROUP: default
      DATABASE_URL: postgres://windmill:${DB_PASSWORD}@db:5432/windmill
    volumes:
      - windmill_cache:/tmp/windmill/cache
      - windmill_logs:/tmp/windmill/logs
    depends_on:
      db:
        condition: service_healthy
    logging: *wm-logging

volumes:
  windmill_pgdata:
  windmill_cache:
  windmill_logs:
EOF
cd ~/selfhost/windmill && docker compose config >/dev/null && echo "compose OK"
```

Assert: `compose OK`. Three services, one port.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. A certificate
attests a public name nothing here has, and browsers treat localhost as secure anyway.

```bash
grep -c '"127.0.0.1:' ~/selfhost/windmill/compose.yml
```

Assert: that prints `1`, the line `- "127.0.0.1:8193:8000"`. Neither the database nor the
worker publishes a port. 8193 answers on this computer only: not the user's phone, not a
laptop on the wifi, nobody on the internet. Jobs still reach out: a loopback binding governs
what arrives, not what a container calls.

## 7. Start and verify

The pull is over a gigabyte and the server migrates the database on the way up.

```bash
cd ~/selfhost/windmill
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8193/api/version); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8193/api/version; echo
curl -sS http://localhost:8193/api/health/status; echo
```

Assert three, printing each. The loop ends on `200`. `/api/version` prints a version string.
`/api/health/status` prints `"database_healthy":true` and `"workers_alive"` of at least `1`;
if it is `0`, read `docker compose logs --tail 40 windmill_worker`. On a port-already-in-use
error, find what holds 8193 with `lsof -nP -iTCP:8193 -sTCP:LISTEN`. A running container is
not success.

Windmill seeds one superadmin, `admin@windmill.dev`, password `changeme`, prefilled on the
login screen. Replace it, then use the new credential for the first workspace and job:

```bash
U=http://localhost:8193
J='Content-Type: application/json'
D='{"email":"admin@windmill.dev","password":"changeme"}'
WM_PASS=$(grep '^WM_ADMIN_PASSWORD=' ~/selfhost/windmill/.env | cut -d= -f2-)
N="{\"email\":\"admin@windmill.dev\",\"password\":\"$WM_PASS\"}"
TOKEN=$(curl -sS -X POST $U/api/auth/login -H "$J" --data "$D")
curl -sS -o /dev/null -w 'setpassword %{http_code}\n' -X POST $U/api/users/setpassword -H "Authorization: Bearer $TOKEN" -H "$J" --data "{\"password\":\"$WM_PASS\"}"
curl -sS -o /dev/null -w 'replay-default %{http_code}\n' -X POST $U/api/auth/login -H "$J" --data "$D"
curl -sS -o /dev/null -w 'unauth-whoami %{http_code}\n' $U/api/users/whoami
T=$(curl -sS -X POST $U/api/auth/login -H "$J" --data "$N")
curl -sS -X POST $U/api/workspaces/create -H "Authorization: Bearer $T" -H "$J" --data '{"id":"main","name":"Main"}'; echo
curl -sS -X POST $U/api/w/main/jobs/run_wait_result/preview -H "Authorization: Bearer $T" -H "$J" --data '{"language":"bash","content":"echo windmill-selfhost-check","args":{}}'; echo
```

Assert five, printing each. `setpassword 200`. `replay-default 400`, the status upstream
returns with the body `Invalid login`, so the seeded credential is dead here too.
`unauth-whoami 401`. Then `Created workspace main`, then `windmill-selfhost-check`: server
queued, worker ran bash, result back. Never print `$WM_PASS` or either token.

STOP: tell the user to open http://localhost:8193, sign in as `admin@windmill.dev` with the
password from `grep WM_ADMIN_PASSWORD ~/selfhost/windmill/.env`, put it in their password
manager, and confirm they land in the `Main` workspace. Do not continue until they confirm.

## 8. First backup and restore

Two artifacts: the database holds every script, flow, app, schedule, run and key; the config
archive rebuilds the service around it.

```bash
cd ~/selfhost/windmill
docker compose exec -T db pg_dump -U windmill -d windmill | gzip > ~/selfhost/windmill/backups/windmill-db-$(date +%F).sql.gz
tar -C ~/selfhost/windmill -czf ~/selfhost/windmill/backups/windmill-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/windmill/backups/
```

Assert: both exist, are non-empty, and print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database, and the volumes hold caches that rebuild.

Those archives sit on the same disk as the data, which is not a backup: on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer,
a sync folder or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is
`/d/Backups`, not `D:\Backups`. Assert: the user confirms both names are there. If there is
nowhere, say so: this has no backup.

To restore: `docker compose down -v`, untar the config archive into ~/selfhost/windmill so
`.env` is back first, `docker compose up -d db`, wait for healthy, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T db psql -U windmill -d windmill`, then
`docker compose up -d`. A server started before the load migrates an empty database.

## 9. Updating later

New versions are listed at https://github.com/windmill-labs/windmill/releases. Expect one most
working days, so the pin is a decision you re-make on your own schedule. The image tag drops
the leading `v`: `v1.789.0` is tag `1.789.0`. PostgreSQL stays on the 16 line upstream runs.
Back up first, then edit both image lines:

```bash
cd ~/selfhost/windmill
docker compose pull
docker compose up -d
docker compose logs --tail 40 windmill_server
```

Watch it settle, then re-run step 7's two checks.

## 10. What will probably go wrong

The disk. I ran this on a laptop with 40 GB free and watched it drop past 25 during the pull,
because one image carries Python, Bun, Deno, Go, PHP, Java, Ruby, .NET and PowerShell so a
worker can run whatever a script is written in. A machine with 12 GB free would have failed
halfway with a message about layers rather than space. The quieter one: Docker Desktop does
not always start after a reboot, and a schedule that should have fired at 9am did not, with
nothing in any log to say why because nothing was running. Run
`cd ~/selfhost/windmill && docker compose up -d` after every reboot.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `NO_AUTH`. Every request then arrives as the `admin@windmill.dev` superadmin.
- Do not mount `/var/run/docker.sock` into the worker. Upstream comments that line out with
  a warning: it hands every script author root on this machine.
- Do not configure SMTP or OAuth. Each is a separate signup.
