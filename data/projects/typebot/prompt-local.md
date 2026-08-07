You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Typebot 3.17.2 and its PostgreSQL under ~/selfhost/typebot: the builder at
http://localhost:8177, the viewer at http://localhost:8977.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install at
all. Every bot this publishes lives at http://localhost:8977 and an id, which means "this
computer" wherever it is read, so a link sent to a colleague or opened on their own phone resolves
to nothing. They get a private place to design and test flows, not a bot others can talk to.

Then the awkward one: Typebot registers no sign-in method until a mail relay is configured, and
that holds here. The user needs a host, port, username, password and a from-address from a
transactional provider before step 4. Tell them now.

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
distribution ID and codename print next, for step 2. Typebot plus PostgreSQL needs 2048 MB of RAM
available and 15 GB free on the home disk, because the two application images are over a gigabyte
each compressed. All three publish amd64 and arm64. Under either floor, print both and stop.

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
  user in one sentence, and tell them the change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose
  plugin with their distribution's package manager, and to run this prompt again once
  `docker info` works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not
continue without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/typebot/backups
ls -la ~/selfhost/typebot
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: bots, results and
credentials are rows in PostgreSQL, which step 5 keeps in a Docker volume, so no ownership
fix is needed anywhere.

## 4. Secrets

Two secrets: the PostgreSQL password and `ENCRYPTION_SECRET`. Generate both here, print neither,
keep both out of your summary and any log line. Upstream documents `openssl rand -base64 24` for
`ENCRYPTION_SECRET`; its schema rejects anything that is not exactly 32 characters, which is what
24 bytes of base64 give.

```bash
cd ~/selfhost/typebot
umask 077
cat > .env <<EOF
NEXTAUTH_URL=http://localhost:8177
NEXT_PUBLIC_VIEWER_URL=http://localhost:8977
NODE_OPTIONS=--no-node-snapshot
DISABLE_SIGNUP=true
DEFAULT_WORKSPACE_PLAN=UNLIMITED
ENCRYPTION_SECRET=$(openssl rand -base64 24)
POSTGRES_PASSWORD=$(openssl rand -hex 32)
ADMIN_EMAIL=CHANGE_ME
NEXT_PUBLIC_SMTP_FROM=CHANGE_ME
SMTP_HOST=CHANGE_ME
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USERNAME=CHANGE_ME
SMTP_PASSWORD=CHANGE_ME
EOF
chmod 600 .env
umask 022
ls -l .env
```

Assert: mode `-rw-------`. Git Bash ships openssl, so these lines run the same everywhere; on
Windows the mode bits are advisory and the real boundary is the user's account.
`DISABLE_SIGNUP` is true from the first boot, and upstream's sign-in callback lets exactly one
address past it: whatever is in `ADMIN_EMAIL`.

STOP: tell the user to open ~/selfhost/typebot/.env, replace every `CHANGE_ME`, put their own
address in `ADMIN_EMAIL`, correct `SMTP_PORT` if their relay is not 587, set `SMTP_SECURE=true` if
it is 465, and save. Do not continue until they confirm, and never ask them to paste a value.

```bash
grep -c CHANGE_ME .env || true
```

Assert: that prints `0`. It counts lines, never values.

## 5. compose.yml

```bash
cat > ~/selfhost/typebot/compose.yml <<'EOF'
# Typebot · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install .. https://docs.typebot.com/self-hosting/deploy/docker
#   configuration ... https://docs.typebot.com/self-hosting/configuration
#
# Three services, paths relative to ~/selfhost/typebot/ so one file works on
# macOS, Linux and Windows. Builder on 8177, viewer on 8977: two Next.js
# servers each owning the root path, and only the builder migrates the
# database. PostgreSQL keeps its data in a named volume, not a bind mount,
# because the image chowns that directory to a uid Docker Desktop cannot grant
# on a Windows home directory. Digests read 2026-08-07, all multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    restart: unless-stopped
    environment:
      POSTGRES_DB: typebot
      POSTGRES_USER: typebot
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - typebot-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U typebot -d typebot"]
      interval: 10s
      retries: 12

  builder:
    image: baptistearno/typebot-builder:3.17.2@sha256:a67edf944eb64e885a3660d8bbd11102b9d468d31dbf4b7f6170e4cd2ceaa9d3
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgresql://typebot:${POSTGRES_PASSWORD}@postgres:5432/typebot
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/api/auth/providers').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
      interval: 15s
      retries: 24
      start_period: 120s
    ports:
      # Loopback only: no other device on the wifi can reach 8177.
      - "127.0.0.1:8177:3000"
    depends_on:
      postgres:
        condition: service_healthy

  viewer:
    image: baptistearno/typebot-viewer:3.17.2@sha256:70f1dd949f2246432650cfda082c01e45089fb129369ceee6632d57b9c5f2b7e
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgresql://typebot:${POSTGRES_PASSWORD}@postgres:5432/typebot
    ports:
      # Loopback only: no other device on the wifi can reach 8977.
      - "127.0.0.1:8977:3000"
    depends_on:
      builder:
        condition: service_healthy

volumes:
  typebot-pgdata:
EOF
cd ~/selfhost/typebot && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Three services, two ports, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. No hostname, so
nothing to resolve. No certificate, because one attests a public name and nothing here has one;
browsers treat http://localhost as a secure context anyway, so pages needing crypto still work.
No firewall rule: nothing is published beyond loopback.

8177 and 8977 are bound to 127.0.0.1, this computer only: not the user's phone, not a laptop on
the same wifi, not anyone on the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/typebot/compose.yml
```

Assert: that prints `2`, one port each for the builder and the viewer. PostgreSQL publishes no
host port, so 5432 cannot appear.

## 7. Start and verify

The first pull is over two gigabytes, and the builder runs migrations before it listens, so the
first boot takes minutes.

```bash
cd ~/selfhost/typebot
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8177/api/auth/providers); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS http://localhost:8177/api/auth/providers
curl -sS http://localhost:8977/api/healthz
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8977/api/typebots
grep -c '^DISABLE_SIGNUP=true$' .env
```

Assert all five, and print what you got for each. The loop ends on `200`. The providers response
is JSON containing `"nodemailer"`, which proves step 4's relay settings were read. The viewer
answers `{"status":"ok"}`. The unauthenticated call to the viewer's API prints `401`,
upstream's answer to a request with no bearer token. The grep prints `1`. If any misses, stop, run
`docker compose logs --tail 60 builder` and name the likely cause: `Invalid environment variables`
points at step 4, where an `ENCRYPTION_SECRET` that is not exactly 32 characters stops the process
before it listens; `{}` from providers means `NEXT_PUBLIC_SMTP_FROM` is empty. If `port is
already allocated` came back, find what holds it (`lsof -nP -iTCP:8177 -sTCP:LISTEN`, or
`netstat -ano | findstr :8177` on Windows) and stop until they free it. A running container is not
success.

The first screen at http://localhost:8177/signin is headed `Sign In`, with `Don't have an account?`
under it and one box asking for an email address next to a `Submit` button.

STOP: tell the user to open http://localhost:8177/signin, enter the address from `ADMIN_EMAIL`,
and type in the six-digit code Typebot mails to it. Do not continue until they confirm they see an
empty bot list. That code arriving is the only proof the relay works; if nothing lands in two
minutes, read step 10.

## 8. First backup and restore

Two artifacts: a dump with every bot, result and stored credential, and an archive of the two
files that rebuild the service.

```bash
cd ~/selfhost/typebot
docker compose exec -T postgres pg_dump -U typebot -d typebot | gzip > ~/selfhost/typebot/backups/typebot-db-$(date +%F).sql.gz
tar -C ~/selfhost/typebot -czf ~/selfhost/typebot/backups/typebot-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/typebot/backups/
```

Assert: both exist and are non-empty. Print both sizes. Nothing is stopped: `pg_dump` snapshots a
running database.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
their sync service watches or a USB stick, and copy both there with `cp`. In Git Bash a Windows
drive is `/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are there. If
not, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/typebot`, untar the archive there first so compose.yml
and .env are back before any container starts: PostgreSQL takes `POSTGRES_PASSWORD` from .env the
moment it initialises an empty volume. Then `docker compose down -v`, the one place `-v` belongs
because it drops the old volume on purpose, `docker compose up -d postgres`, wait 30 seconds, pipe
`gunzip -c` on the `.sql.gz` into `docker compose exec -T postgres psql -U typebot -d typebot`,
then `docker compose up -d`. `ENCRYPTION_SECRET` decrypts the provider keys in that dump, so a
restore beside a fresh secret is unreadable.

## 9. Updating later

New versions are listed at https://github.com/baptisteArno/typebot.io/releases. Take both backups
first, then edit both `image:` lines in ~/selfhost/typebot/compose.yml to the new tag and digest,
builder and viewer on one version:

```bash
cd ~/selfhost/typebot
docker compose pull
docker compose up -d
docker compose logs --tail 40 builder
```

Watch that log until it settles, then re-run step 7's checks.

## 10. What will probably go wrong

I rebooted this machine, opened the builder, and got a connection error that read like a lost
database. It was not: Docker Desktop had not started with the session, so nothing listened on
8177 or 8977, and `restart: unless-stopped` acts only once the daemon is up. Turn on Docker
Desktop's start-at-login setting, then after a reboot run
`cd ~/selfhost/typebot && docker compose up -d` before concluding anything is broken. The other
one is the sign-in code not arriving, the relay refusing it out of sight: read
`docker compose logs --tail 60 builder`, then the spam folder.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8177 or 8977 to 0.0.0.0 so a phone can reach them. That puts a bot builder and
  everything typed into it on every network the user joins.
- Do not configure Google, GitHub, GitLab or Azure AD sign-in. Each needs a client registered in
  somebody else's console; this install signs people in by email.
- Do not add S3 storage or MinIO. Media uploads inside bots stay off here.
