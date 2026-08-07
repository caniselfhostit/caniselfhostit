You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Zipline 4.6.5, with the PostgreSQL it keeps accounts and links in, under
~/selfhost/zipline, answering at http://localhost:8156.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
Every link this hands back begins with http://localhost:8156, and `localhost` means "the
computer you are reading this on" to whoever opens it, so a link pasted into a chat opens for
the user and fails for everyone else. This is a private drop box, not a share service.

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
distribution ID and codename print next, for step 2. Zipline plus PostgreSQL needs 2048 MB of
RAM available and 10 GB free on the home disk, and both images publish amd64 and arm64. That
floor is the thumbnail workers rather than the web server: the image ships ffmpeg and renders
video thumbnails on four threads. On macOS and Windows the memory printed is the host's, out of
which Docker Desktop takes its own. If RAM is under 2048 MB or free disk under 10 GB, print both
and stop.

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
mkdir -p ~/selfhost/zipline/uploads ~/selfhost/zipline/backups
ls -la ~/selfhost/zipline
```

Assert: `ls -la` shows `uploads` and `backups`, both owned by the user. No ownership fix runs on
any of the three systems: the database lives in a volume Docker manages. The container writes
into `uploads` as root, which step 10 covers.

## 4. Secrets

Two secrets, both generated here: the PostgreSQL password and `CORE_SECRET`, which signs session
cookies. Print neither, and keep both out of your summary and out of any log line. Hex rather
than base64: one travels inside a connection string, and upstream refuses to start on a secret
under 32 characters, which 32 hex bytes clears.

```bash
umask 077
cat > ~/selfhost/zipline/.env <<EOF
CORE_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/zipline/.env
umask 022
ls -l ~/selfhost/zipline/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so this runs the same on
all three systems. On Windows those mode bits are advisory: NTFS does not enforce them,
and the real boundary is the user's own Windows account. Changing `CORE_SECRET` later logs every
session out, so tell the user to leave it alone once this works.

## 5. compose.yml

```bash
cat > ~/selfhost/zipline/compose.yml <<'EOF'
# Zipline · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install ..... https://zipline.diced.sh/docs/get-started/docker
#   variable reference . https://zipline.diced.sh/docs/config
#   hardening guide .... https://zipline.diced.sh/docs/guides/hardening
#
# Two services, every path relative to ~/selfhost/zipline/ so one file works on
# macOS, Linux and Windows. Uploads stay a bind mount you can open in Finder;
# the database is a named volume, because PostgreSQL chowns its data directory
# to its own uid and a home-directory bind mount cannot allow that on Windows.
# Digests read on 2026-08-07; both images publish amd64 and arm64.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  postgres:
    image: postgres:16.14-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: zipline-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: zipline
      POSTGRES_USER: zipline
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - zipline-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zipline -d zipline"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  zipline:
    image: ghcr.io/diced/zipline:4.6.5@sha256:bfd5b0f7b5b8b3ed058a81667c78a14a7f997115d8433bec273620ec81be51d4
    container_name: zipline
    restart: unless-stopped
    env_file: ./.env
    environment:
      DATABASE_URL: postgres://zipline:${DB_PASSWORD}@postgres:5432/zipline
      # No proxy and no certificate here, so plain http. Registration stays
      # closed once the wizard has made the first account. The file type is
      # read off the file rather than believed, and the two that execute in a
      # browser are served as a download.
      CORE_TRUST_PROXY: "false"
      CORE_RETURN_HTTPS_URLS: "false"
      FEATURES_USER_REGISTRATION: "false"
      FILES_ASSUME_MIMETYPES: "true"
      FILES_DISABLED_TYPES: text/html,application/javascript
      FILES_DISABLED_TYPES_DEFAULT: application/octet-stream
    volumes:
      - ./uploads:/zipline/uploads
    ports:
      # Loopback only: no other device on the wifi can reach 8156.
      - "127.0.0.1:8156:3000"
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  zipline-pgdata:
EOF
cd ~/selfhost/zipline && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Files land in ~/selfhost/zipline/uploads; everything else
about them, the owner, the short code, the view count, is a row in PostgreSQL. That is why step
8 takes two artifacts.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. Each is a decision:

- No DNS. There is no hostname, so nothing to resolve and nothing to wait for.
- No TLS. A certificate attests a public name and nothing here has one. Browsers treat
  http://localhost as a secure context anyway, so the upload code still works.
- No firewall rule. Nothing is published beyond loopback, so no port needs closing.

8156 is bound to 127.0.0.1: not the user's phone, not a laptop on the same wifi, not anyone on
the internet. For a file host that is the whole shape of the trade. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/zipline/compose.yml
```

Assert: that prints `1`, the one published port `- "127.0.0.1:8156:3000"`. PostgreSQL publishes
no host port, so 5432 cannot appear.

## 7. Start and verify

Zipline migrates its own database on the way up, so the first start is the slow one.

```bash
cd ~/selfhost/zipline
docker compose pull
docker compose up -d
for i in $(seq 1 30); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8156/api/healthcheck); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8156/api/healthcheck
curl -sS http://localhost:8156/api/setup
```

Assert all three, and print what you received for each: the loop ends on `200`; the health call
prints `{"pass":true}`, upstream's answer when server and database are up; the setup call prints
`{"firstSetup":true}`, this instance saying it has no accounts yet. If any of the three
misses, stop, run `docker compose logs --tail 40 zipline` and
`docker compose logs --tail 20 postgres`, and name the likely cause: a database that never
reports healthy points at step 4, where an empty `DB_PASSWORD` leaves PostgreSQL refusing to
start, and a zipline log still in migrations wants more time. If `port is already allocated`
came back, find what holds 8156 (`lsof -nP -iTCP:8156 -sTCP:LISTEN`, or
`netstat -ano | findstr :8156` on Windows) and stop until the user frees it. A running container
is not success.

The first screen is at http://localhost:8156/auth/setup and its heading reads
`Welcome to Zipline!`, above a stepper with a `Username` and a `Password` field.

STOP: tell the user to open http://localhost:8156/auth/setup, create the first account, then,
still logged in, open Settings from the user menu at the top right, scroll to
`Generate Uploaders`, and download the `ShareX` config on Windows or the `Flameshot` script on
Linux and macOS. That download is the point of this install: it aims the screenshot tool they
already have at this machine. Wait. Do not continue until they confirm both.

Once they confirm, prove the door is shut:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8156/api/setup
curl -sS http://localhost:8156/api/server/public | grep -oE '"(userRegistration|firstSetup)":[a-z]+'
```

Assert: the first prints `403`, upstream's answer once the wizard is claimed, so no second
superadmin can be made through it. The second prints `"userRegistration":false` and
`"firstSetup":false`. Both must pass before you report success.

## 8. First backup and restore

Two artifacts, neither worth anything alone: a database dump with the accounts, tokens, short
links and one row per file, and an archive with the files plus the two config files that rebuild
the service around them.

```bash
cd ~/selfhost/zipline
docker compose exec -T postgres pg_dump -U zipline -d zipline | gzip > ~/selfhost/zipline/backups/zipline-db-$(date +%F).sql.gz
tar -C ~/selfhost/zipline -czf ~/selfhost/zipline/backups/zipline-files-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/zipline/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped:
`pg_dump` snapshots a running database consistently. On Linux `tar` may need `sudo`; step 10
says why.

Both archives sit on the same disk as the data, which is not a backup, and on a laptop the disk
and the machine fail together. Ask the user for a destination that leaves this computer, a folder
a sync service watches or a USB stick, and copy both there with `cp`. In Git Bash a Windows
drive is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are
there. If they have neither, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/zipline`, untar the files archive there first so
compose.yml and .env are back before any container starts: PostgreSQL reads `DB_PASSWORD` from
.env the moment it initialises an empty volume, and a missing .env means a blank password and a
database that will not start. Then `docker compose down -v`, the one place `-v` belongs because
it drops the old volume on purpose, `docker compose up -d postgres`, wait 30 seconds, pipe
`gunzip -c` on the `.sql.gz` into
`docker compose exec -T postgres psql -U zipline -d zipline`, then `docker compose up -d`. Open
one old link and check the file comes back. That is the whole disaster plan.

## 9. Updating later

New versions are at https://github.com/diced/zipline/releases. Take both backups first, then
edit the image line in ~/selfhost/zipline/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/zipline
docker compose pull
docker compose up -d
docker compose logs --tail 30 zipline
```

Watch that log until it settles, then re-run step 7's health check.

## 10. What will probably go wrong

On Linux I tried to clear a test upload out of my file manager and got permission denied on a
file I had made myself. Nothing was broken: the Zipline image runs as root,
so everything under ~/selfhost/zipline/uploads belongs to root even though the folder belongs to
the user. Deleting from inside the dashboard works; from the desktop it needs `sudo`. On macOS
and Windows, Docker Desktop rewrites ownership on the way through and none of it appears.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not set `CORE_DEFAULT_DOMAIN` to this machine's LAN address and do not rebind 8156 to
  0.0.0.0 so a phone can reach it. That puts a file host with an upload API on every network
  the user joins.
- Do not switch the datasource to S3. Local storage under ~/selfhost/zipline/uploads is the
  choice here, and the one step 8 backs up.
