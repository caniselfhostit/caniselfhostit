You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Docmost 0.95.0, with the PostgreSQL and Redis it needs, under ~/selfhost/docmost,
answering at http://localhost:8092.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
The wiki answers on this computer and nowhere else. Nobody they invite can reach it, their
own phone cannot, and every shared-page link Docmost builds begins with http://localhost:8092,
which means "this computer" to whoever opens it. A team of one is the honest use of this path.

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
distribution ID and codename print next, for step 2. Docmost plus PostgreSQL plus Redis needs
2048 MB of RAM available and 10 GB free on the home disk, and all three images publish amd64
and arm64. If available RAM is under 2048 MB or free disk is under 10 GB, print both numbers
and stop. Do not install and hope.

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
mkdir -p ~/selfhost/docmost/storage ~/selfhost/docmost/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/docmost/storage
fi
ls -la ~/selfhost/docmost
```

Assert: `ls -la` shows `storage` and `backups`. Attachments land in `storage`, and Docmost runs
as its base image's `node` user, uid 1000, so on Linux that folder is handed to uid 1000. The
guard skips on macOS and Windows, where Docker Desktop's file sharing handles it.

## 4. Secrets

Two secrets: the application secret Docmost signs sessions with, and the PostgreSQL password.
Generate both here, print neither, and keep both out of your summary and any log line.
Upstream states the app refuses to start if `APP_SECRET` keeps its shipped default.

```bash
umask 077
cat > ~/selfhost/docmost/.env <<EOF
APP_URL=http://localhost:8092
APP_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/docmost/.env
umask 022
ls -l ~/selfhost/docmost/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same everywhere. Hex rather than base64, because `DB_PASSWORD` goes into a PostgreSQL
connection string in step 5. On Windows those mode bits are advisory: NTFS does not enforce
them, and the real boundary is the user's own Windows account.

## 5. compose.yml

```bash
cat > ~/selfhost/docmost/compose.yml <<'EOF'
# Docmost · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   installation ....... https://docmost.com/docs/installation
#   variable reference . https://docmost.com/docs/self-hosting/environment-variables
#   image ............. https://github.com/docmost/docmost/blob/main/Dockerfile
#
# Three services on the computer you are sitting at. Paths are relative to
# ~/selfhost/docmost/, so one file works on macOS, Linux and Windows. The
# database and Redis are named volumes rather than folders you can open,
# because both images chown their own data directory and a home-directory
# bind mount cannot grant that on Windows. Attachments stay a real folder,
# ./storage, owned by uid 1000, the node user Docmost runs as. Digests read
# on 2026-08-05; all three images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:18.4-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
    container_name: docmost-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: docmost
      POSTGRES_USER: docmost
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - docmost-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U docmost -d docmost"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 stays on the compose network.

  redis:
    image: redis:8.10.0-alpine@sha256:978f0e01593e65eed801f2402944efcd936d43b5027e4908a7897baf88ed6241
    container_name: docmost-redis
    restart: unless-stopped
    # appendonly persists every change; noeviction makes Redis refuse writes
    # rather than silently drop a queued job when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "noeviction"]
    volumes:
      - docmost-redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 6379 stays on the compose network.

  docmost:
    image: docmost/docmost:0.95.0@sha256:41c8d777cf23c74e78f94e676aec328b7d7856f48df5e573543dac68d371e37c
    container_name: docmost
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgresql://docmost:${DB_PASSWORD}@postgres:5432/docmost
      REDIS_URL: redis://redis:6379
      # Attachments land in ./storage. No S3 or Azure account.
      STORAGE_DRIVER: local
    volumes:
      - ./storage:/app/data/storage
    ports:
      # Loopback only: no other device can reach 8092.
      - "127.0.0.1:8092:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  docmost-pgdata:
  docmost-redis:
EOF
cd ~/selfhost/docmost && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Compose fills `${DB_PASSWORD}` from `.env` in this
directory, so one generated value reaches both PostgreSQL and the connection string.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the editor still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8092 is bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on the same
wifi, nobody on the internet. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/docmost/compose.yml
```

Assert: one line, `- "127.0.0.1:8092:3000"`. PostgreSQL and Redis publish no host port at all.

## 7. Start and verify

Docmost migrates its own database on the way up, so the first start is the slow one.

```bash
cd ~/selfhost/docmost
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8092/api/health); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8092/api/health
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8092/api/workspace/public
```

Assert all three, and print what you received for each: the loop ends on `200`; the health body
contains `"status":"ok"` and reports both `database` and `redis` as `up`; the third prints
`404`, because no workspace exists yet. If any of the three misses, stop, run
`docker compose logs --tail 40 docmost` and `docker compose logs --tail 20 postgres`, and name
the likely cause: an empty `DB_PASSWORD` from step 4 leaves PostgreSQL refusing to start, and a
log still in migrations wants more time. If `port is already allocated` came back, find what
holds 8092 (`lsof -nP -iTCP:8092 -sTCP:LISTEN`, or `netstat -ano | findstr :8092` on Windows)
and stop until the user frees it. A running container is not success.

The first screen at http://localhost:8092/setup/register shows the heading `Create workspace`
above fields for a workspace name, a name, an email and a password of at least 8 characters.

STOP: tell the user to open that page, create the workspace and their own account, and wait. Do
not continue until they confirm. That first account becomes the workspace owner.

Once they confirm, prove that first-run registration is now closed:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://localhost:8092/api/workspace/public
curl -sS -w '\n%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' http://localhost:8092/api/auth/setup
```

Assert: the first prints `200`, so the workspace exists. The second returns a 403 whose body
contains `Workspace setup already completed.` Both must pass before you report success.

## 8. First backup and restore

Two artifacts: a database dump with every page, space and user, and a file archive with the
attachments and the two files that rebuild it.

```bash
cd ~/selfhost/docmost
docker compose exec -T postgres pg_dump -U docmost -d docmost | gzip > ~/selfhost/docmost/backups/docmost-db-$(date +%F).sql.gz
tar -C ~/selfhost/docmost -czf ~/selfhost/docmost/backups/docmost-files-$(date +%F).tar.gz storage compose.yml .env
ls -lh ~/selfhost/docmost/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently, and Redis stays out of the backup because
it holds live editor sessions and queued jobs, not content.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a
folder their sync service watches or a USB stick, and copy both there with `cp`. In Git Bash a
Windows drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms both files
are there. If they have neither, say that this install has no backup.

To restore, in this order. `cd ~/selfhost/docmost`, untar the file archive there first, so
compose.yml and .env are back before any container starts: PostgreSQL takes `DB_PASSWORD` from
.env the moment it initialises an empty volume, and a different password gives an
authentication error that says nothing about passwords. Then `docker compose down -v`, the one
place `-v` belongs, `docker compose up -d postgres`, wait 30 seconds for healthy, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U docmost -d docmost`,
then `docker compose up -d`. Open a page and check its text and attachments are there.

## 9. Updating later

New versions are listed at https://github.com/docmost/docmost/releases. Take both backups
first, then edit the image line in ~/selfhost/docmost/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/docmost
docker compose pull
docker compose up -d
docker compose logs --tail 30 docmost
```

Watch that log until it settles, then re-run step 7's health check before calling it done.

## 10. What will probably go wrong

I left a page open, closed the laptop, and came back an hour later to an editor that would not
take a keystroke. It looked like data loss. It was not: the editor holds its session over a
WebSocket, sleeping the machine kills that socket, and the page then sits there looking
editable while nothing typed into it goes anywhere. Reloading the tab fixed it every time. If
it does not, run `cd ~/selfhost/docmost && docker compose ps` first: Docker Desktop does not
always come back after a reboot, and `restart: unless-stopped` acts only once its daemon is
up.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8092 to 0.0.0.0 so a phone can reach it. `APP_URL` would still say localhost,
  and the wiki would be readable by every device on whatever network this machine joins next.
- Do not configure SMTP. Invitations can be handed out as links from the members page.
- Do not add a license key. Bases, SSO, AI, audit logs and SCIM are sold separately and are not
  part of this install.
