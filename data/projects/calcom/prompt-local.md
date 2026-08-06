You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Cal.com 6.2.0, with the PostgreSQL it stores bookings in, under ~/selfhost/calcom,
answering at http://localhost:8094.

## 1. Preflight

Say this to the user before step 2; it decides whether they want this install at all. Cal.com's
product is a link other people open to book time with you, and this one is
http://localhost:8094, which means "this computer" wherever it is read. Nobody else can open it,
their own phone included. They get a scheduling app they drive themselves and a page nobody
else can load.

Detect the OS and measure:

```bash
uname -s
uname -m
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. `uname -m`
decides one line in step 5: an Apple Silicon Mac prints `arm64`. This install needs 4096 MB of
RAM available and 15 GB free on the home disk, and Docker Desktop's virtual machine wants at
least 4 GB of that in its own settings. If either floor is missed, print both numbers and stop.

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
mkdir -p ~/selfhost/calcom/backups
ls -la ~/selfhost/calcom
```

Assert: `ls -la` shows `backups`, owned by the user. There is no `data` folder: bookings and
calendar credentials are rows in PostgreSQL, kept in a volume Docker manages, so no ownership
fix is needed.

## 4. Secrets

Three secrets: the PostgreSQL password, the NextAuth session secret, and the encryption key over
saved calendar credentials. Generate all three here, print none, keep them out of your summary
and logs. Upstream documents `openssl rand -base64 32` and `openssl rand -base64 24` for
the two Cal.com ones.

```bash
cd ~/selfhost/calcom
umask 077
cat > .env <<EOF
NEXT_PUBLIC_WEBAPP_URL=http://localhost:8094
NEXT_PUBLIC_WEBSITE_URL=http://localhost:8094
CALCOM_TELEMETRY_DISABLED=1
POSTGRES_PASSWORD=$(openssl rand -hex 32)
NEXTAUTH_SECRET=$(openssl rand -base64 32)
CALENDSO_ENCRYPTION_KEY=$(openssl rand -base64 24)
EMAIL_FROM=CHANGE_ME
EMAIL_FROM_NAME=CHANGE_ME
EMAIL_SERVER_HOST=CHANGE_ME
EMAIL_SERVER_PORT=587
EMAIL_SERVER_USER=CHANGE_ME
EMAIL_SERVER_PASSWORD=CHANGE_ME
EOF
chmod 600 .env
umask 022
ls -l .env
```

Assert: mode `-rw-------`. On Windows those bits are advisory; the real boundary is the user's
own account. `CALENDSO_ENCRYPTION_KEY` cannot be regenerated: calendar connections are
encrypted with it. The five `CHANGE_ME` lines are the outbound relay, and an invitee learns
their booking exists by mail or not at all.

STOP: tell the user to open ~/selfhost/calcom/.env in an editor, replace every `CHANGE_ME` with
the matching value from their mail relay, correct `EMAIL_SERVER_PORT` if it is not 587, save,
and confirm. Do not continue until they do, and never ask them to paste those values to you.

```bash
grep -c CHANGE_ME .env || true
```

Assert: that prints `0`. It counts lines, never values.

## 5. compose.yml

```bash
cat > ~/selfhost/calcom/compose.yml <<'EOF'
# Cal.com · the deterministic fallback for the local path. Authored by
# caniselfhostit from https://github.com/calcom/cal.diy at tag v6.2.0
# (docs/self-hosting/docker.mdx, .env.example, Dockerfile, scripts/start.sh),
# not copied from a repository.
#
# Every path is relative to ~/selfhost/calcom/, so one file works on macOS,
# Linux and Windows. The database is a named volume rather than a bind mount
# because the PostgreSQL image chowns its data directory to its own uid, which
# Docker Desktop's Windows file sharing cannot grant on a home directory. The
# entrypoint rewrites the built-in URL to NEXT_PUBLIC_WEBAPP_URL and migrates on
# every fresh container, so a first boot takes minutes and the health check
# below adds a start period.
#
# Digests read on 2026-08-05. The v6.2.0 tag is amd64 only; arm64 ships as the
# separate v6.2.0-arm tag.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: calcom-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: calcom
      POSTGRES_USER: calcom
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - calcom-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U calcom -d calcom"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  calcom:
    image: calcom/cal.com:v6.2.0@sha256:ace3bb1219fb7306585ab9f4d94d41af7ee064c343db0498173436bbe857bd49
    container_name: calcom
    restart: unless-stopped
    env_file: ./.env
    environment:
      # start.sh waits on this host:port pair before migrating.
      DATABASE_HOST: postgres:5432
      DATABASE_URL: postgresql://calcom:${POSTGRES_PASSWORD}@postgres:5432/calcom
      # Prisma migrates over the direct URL. No pooler, so the same address.
      DATABASE_DIRECT_URL: postgresql://calcom:${POSTGRES_PASSWORD}@postgres:5432/calcom
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:3000 || exit 1"]
      interval: 30s
      timeout: 30s
      retries: 5
      start_period: 900s
    ports:
      # Loopback only: no other device on the wifi can reach 8094.
      - "127.0.0.1:8094:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  calcom-pgdata:
EOF
```

That pins the amd64 build. Upstream ships no multi-architecture manifest, so if step 1 printed
`arm64` or `aarch64`, switch the image line:

```bash
cd ~/selfhost/calcom
case "$(uname -m)" in
  arm64|aarch64) sed 's|:v6.2.0@sha256:[a-f0-9]*|:v6.2.0-arm@sha256:4b0fa72eec13bd3ddb608a6d13f05bf0ebc136e73832abfe1a8ec145db9e4651|' compose.yml > compose.arm && mv compose.arm compose.yml ;;
esac
grep -n 'image:' compose.yml
docker compose config >/dev/null && echo "compose OK"
```

Assert: `grep` prints two image lines, the Cal.com one carrying `-arm` on arm64, and the last
prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway.
- No firewall rule. Nothing is published beyond loopback, so nothing needs closing.

8094 is bound to 127.0.0.1: not the phone, not a laptop on the wifi, not anyone they want to
meet. Confirm:

```bash
grep -n '127.0.0.1' compose.yml
```

Assert: one line, `- "127.0.0.1:8094:3000"`. PostgreSQL publishes none.

## 7. Start and verify

On a fresh container the entrypoint rewrites every compiled-in copy of the built URL, waits for
PostgreSQL, migrates and seeds before Next.js listens. Budget fifteen minutes.

```bash
cd ~/selfhost/calcom
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:8094/auth/setup?step=1"); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS "http://localhost:8094/auth/setup?step=1" | grep -o '<title>[^<]*</title>'
```

Assert both, and print what you received. The loop ends printing `200`, and the title line reads
exactly `<title>Setup | Cal.com</title>`. If either misses, stop, run
`docker compose logs --tail 60 calcom`, and name the cause: a database that never reports
healthy points at step 4, where an empty `POSTGRES_PASSWORD` stops PostgreSQL starting; a log
still printing migration names wants more time; `port is already allocated` means something else
holds 8094. A running container is not success.

The first screen at http://localhost:8094/auth/setup?step=1 is a wizard headed
`Administrator user`, with `Let's create the first administrator user.` under it.

STOP: tell the user to open that address, create the first account, and wait. Do not continue
until they confirm. Upstream's password rule is strict: 15 characters at least, one number, both
cases. Step 2 asks for a licence, and the free AGPLv3 option is this one.

Once they confirm, close registration and prove it is closed:

```bash
cd ~/selfhost/calcom
printf 'NEXT_PUBLIC_DISABLE_SIGNUP=true\n' >> .env
docker compose up -d --force-recreate calcom
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:8094/auth/login"); echo "$i $code"; [ "$code" = 200 ] && break; sleep 15; done
curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "http://localhost:8094/signup"
```

Assert: the last line is a 3xx status whose redirect URL contains `/auth/error`, and the loop is
slow again because recreating rewrites the built URL. The `Create an account` link stays on the
login page, drawn by JavaScript compiled into the image, but the page behind it refuses.

## 8. First backup and restore

Two artifacts: the database holds every booking and encrypted calendar credential, the config
archive what rebuilds the service around it.

```bash
cd ~/selfhost/calcom
docker compose exec -T postgres pg_dump -U calcom -d calcom | gzip > backups/calcom-db-$(date +%F).sql.gz
tar -czf backups/calcom-config-$(date +%F).tar.gz compose.yml .env
ls -lh backups/
```

Assert: both exist and are non-empty. Print both sizes. `pg_dump` snapshots a running database,
so nothing stops.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a folder their
sync service watches or a USB stick, and copy both there with `cp`. Assert: the user confirms
both filenames are listed there. If they have neither, say plainly that there is no backup.

To restore, in this order. In ~/selfhost/calcom, untar the config archive first, so compose.yml
and .env are back before any container starts: PostgreSQL takes `POSTGRES_PASSWORD` from .env
the moment it initialises an empty volume. Then `docker compose down -v`, the one place `-v`
belongs, `docker compose up -d postgres`, wait 30 seconds, pipe `gunzip -c` on the
`.sql.gz` into `docker compose exec -T postgres psql -U calcom -d calcom`, then
`docker compose up -d`. The archive matters as much as the dump: those credentials are encrypted
with a key that lives only in .env.

## 9. Updating later

New versions are listed at https://github.com/calcom/cal.diy/releases. Take both backups first,
then edit the image line in compose.yml to the new tag and digest, keeping `-arm` on an arm64
machine:

```bash
cd ~/selfhost/calcom
docker compose pull
docker compose up -d
docker compose logs --tail 40 calcom
```

Watch that log until it settles, then re-run step 7's health check before calling it done.

## 10. What will probably go wrong

The first boot looks like a failed install for a long time. I watched `curl` return nothing at
all for eleven minutes on a MacBook and started reading the compose file for a mistake. There
was none: the entrypoint was still rewriting the compiled output, then migrating, then seeding.
Read `docker compose logs -f calcom` rather than restarting, because a restart begins that whole
sequence again.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not change `NEXT_PUBLIC_WEBAPP_URL` to this machine's LAN address and do not rebind 8094 to
  0.0.0.0 so a phone can reach it. That puts a calendar on every network the user joins.
- Do not configure Google Calendar or Outlook sync, which needs an OAuth client registered in
  the user's own Google Cloud or Azure tenant, and do not set `CALCOM_LICENSE_KEY`.
