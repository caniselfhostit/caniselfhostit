You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install FitTrackee 1.3.4, with the PostgreSQL it stores workouts in, under
~/selfhost/fittrackee, answering at http://localhost:8129.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
FitTrackee answers only at http://localhost:8129, so the phone that recorded the ride cannot
reach it: every workout arrives as a file copied onto this machine and uploaded in a browser.

Detect the OS and measure the machine:

```bash
uname -s
case "$(uname -s)" in
  Darwin) vm_stat | awk '/page size/{p=$8} /free|inactive/{s+=$3} END {printf "%d MB available\n", s*p/1048576}' ;;
  Linux) . /etc/os-release && echo "$ID $VERSION_CODENAME"; uname -m; free -m | awk '/^Mem:/ {print $7 " MB available of " $2 " MB"}' ;;
  MINGW*|MSYS*) powershell -Command "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" | awk '$1+0 {printf "%d MB available\n", $1/1024}' ;;
esac
df -h ~
```

`Darwin` is macOS, `Linux` is Linux, `MINGW` or `MSYS` is Windows under Git Bash. This needs
2048 MB of RAM available and 10 GB free on the home disk. PostGIS is a mandatory prerequisite
and its image publishes linux/amd64 only, in upstream's own words, so an Apple Silicon Mac runs
the database under Docker Desktop's emulation. Stop on a Linux machine where `uname -m` prints
`aarch64`: no emulation layer is there by default. If available RAM is under 2048 MB or free
disk under 10 GB, print both numbers and stop.

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
mkdir -p ~/selfhost/fittrackee/uploads ~/selfhost/fittrackee/staticmap_cache ~/selfhost/fittrackee/backups
if [ "$(uname -s)" = "Linux" ]; then
  sudo chown -R 1000:1000 ~/selfhost/fittrackee/uploads ~/selfhost/fittrackee/staticmap_cache
fi
ls -la ~/selfhost/fittrackee
```

Assert: `ls -la` shows all three. The container runs as uid 1000 and upstream requires the first
two writable by it, so on Linux they are chowned to match; on macOS and Windows Docker Desktop
maps ownership itself and the fence is a no-op. The database lives in a volume Docker manages,
so there is no folder for it here.

## 4. Secrets

Two secrets: the PostgreSQL password and `APP_SECRET_KEY`, upstream's key for JWT generation.
Generate both here, print neither, keep both out of your summary and any log line.

```bash
umask 077
cat > ~/selfhost/fittrackee/.env <<EOF
UI_URL=http://localhost:8129
POSTGRES_PASSWORD=$(openssl rand -hex 32)
APP_SECRET_KEY=$(openssl rand -hex 48)
EOF
chmod 600 ~/selfhost/fittrackee/.env
umask 022
ls -l ~/selfhost/fittrackee/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same on all three systems. Compose reads it for the `${...}` substitutions in compose.yml and
passes it to the container, so one password reaches both the database and the connection string.
On Windows those mode bits are advisory: NTFS does not enforce them, and the user's own account
is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/fittrackee/compose.yml <<'EOF'
# FitTrackee · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install . https://docs.fittrackee.org/en/installation/installation.html
#   variables ...... https://docs.fittrackee.org/en/installation/environments_variables.html
#   emails ......... https://docs.fittrackee.org/en/installation/emails.html
#
# Two services, every path relative to ~/selfhost/fittrackee/ so one file works
# on macOS, Linux and Windows. PostGIS 3.4+ is a mandatory prerequisite, so the
# database image is postgis/postgis, which publishes linux/amd64 only, in
# upstream's own words. It is a named volume, not a bind mount, because
# PostgreSQL chowns its data directory. Digests read 2026-08-06.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  fittrackee-db:
    image: postgis/postgis:18-3.6-alpine@sha256:22e5371710d26bae9b4f3b28f962bcfddecbf8ba8c9e8357ece4ca18858ede28
    platform: linux/amd64
    container_name: fittrackee-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: fittrackee
      POSTGRES_USER: fittrackee
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - fittrackee-pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U fittrackee -d fittrackee"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other container.

  fittrackee:
    image: fittrackee/fittrackee:v1.3.4@sha256:87ebf6879eccad561e84b257eb1ec825030030d6b0142fbaef0048c7d8cc29ba
    container_name: fittrackee
    restart: unless-stopped
    env_file: ./.env
    environment:
      FLASK_APP: fittrackee
      FLASK_SKIP_DOTENV: "1"
      DATABASE_URL: postgresql://fittrackee:${POSTGRES_PASSWORD}@fittrackee-db:5432/fittrackee
      UPLOAD_FOLDER: /usr/src/app/uploads
      STATICMAP_CACHE_DIR: /usr/src/app/.staticmap_cache
      # Console logging, so /usr/src/app/logs never has to exist.
      GUNICORN_LOG: "-"
      # Empty on purpose: no mail server, so no Redis and no worker.
      EMAIL_URL: ""
    command: sh docker-entrypoint.sh
    volumes:
      - ./uploads:/usr/src/app/uploads
      - ./staticmap_cache:/usr/src/app/.staticmap_cache
    ports:
      # Loopback only: no other device on the wifi can reach 8129.
      - "127.0.0.1:8129:5000"
    depends_on:
      fittrackee-db:
        condition: service_healthy

volumes:
  fittrackee-pgdata:
EOF
cd ~/selfhost/fittrackee && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`. Two services, one published port, two bind mounts, one named
volume, no Redis.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve. A certificate attests a public name and nothing here has one; browsers treat
http://localhost as a secure context anyway, so pages needing crypto still work. Nothing is
published beyond loopback, so no port needs closing: 8129 is bound to 127.0.0.1, which is not the
user's phone, not a laptop on the wifi, and not anyone on the internet. Confirm that:

```bash
grep -n '127.0.0.1' ~/selfhost/fittrackee/compose.yml
```

Assert: one line, `- "127.0.0.1:8129:5000"`. PostgreSQL publishes no host port, so 5432 cannot
appear.

## 7. Start and verify

FitTrackee runs its migrations on the way up, slowest on the first start and slower again where
the database is emulated. Registration also ships open, because upstream's active-users limit is
0 and 0 means no limit, so this block starts the service and sets that limit to one in the same
pass, writing it into the row because there is no environment variable and no CLI command for
it.

```bash
cd ~/selfhost/fittrackee
docker compose pull
docker compose up -d
for i in $(seq 1 40); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8129/api/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8129/api/check-db
curl -sS http://localhost:8129/ | grep -o '<title>[^<]*</title>'
docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -c "UPDATE app_config SET max_users = 1;"
docker compose restart fittrackee
sleep 20
curl -sS http://localhost:8129/api/config
```

Assert all five, and print what you received for each: the loop ends on `200`; `/api/check-db`
returns `"db available"`; the title line prints `<title>FitTrackee</title>`; psql prints
`UPDATE 1`; the config JSON contains `"version":"1.3.4"`, `"max_users":1` and
`"is_registration_enabled":true`. That last pair is correct: FitTrackee allows a registration
while the account count is under the limit, so exactly one person can still sign up. If anything
misses, stop, run `docker compose logs --tail 40 fittrackee` and
`docker compose logs --tail 20 fittrackee-db`, and name the likely cause: a database that never
reports healthy points at step 4, where an empty `POSTGRES_PASSWORD` leaves PostgreSQL refusing
to start. On `port is already allocated`, find what holds 8129 with
`lsof -nP -iTCP:8129 -sTCP:LISTEN`.

STOP: tell the user to open http://localhost:8129/register, create their account with a
username, their email address and a password of at least 8 characters, and wait. Do not continue
until they confirm. Warn them first that FitTrackee will say the account needs confirming by
email, that this install sends no mail, and that they cannot sign in until the next command
runs.

```bash
cd ~/selfhost/fittrackee
FTUSER=$(docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee -tAc "SELECT username FROM users ORDER BY id LIMIT 1")
echo "account: $FTUSER"
docker compose exec -T fittrackee ftcli users update "$FTUSER" --set-role owner
curl -sS http://localhost:8129/api/config
```

Assert all three: `account:` prints the username the user typed, the CLI exits 0, and the config
JSON now reads `"is_registration_enabled":false`. That is the security assert here: with one
account against a limit of one, FitTrackee closes its own registration form. The owner role also
activates the account, upstream's answer on an instance with no mail.

The first screen at http://localhost:8129 shows a `Login` heading over an `Email` box and a
`Password` box, with `Forgot password?` beneath them and no `Register` link.
http://localhost:8129/register now answers `Sorry, registration is disabled.`

STOP: tell the user to sign in at http://localhost:8129 and confirm their dashboard loads, and
wait. Do not continue until they confirm. A running container is not success.

## 8. First backup and restore

Two artifacts: the database holds every workout and everything computed from it, the config
archive the track files and the two files that rebuild the service.

```bash
cd ~/selfhost/fittrackee
docker compose exec -T fittrackee-db pg_dump -U fittrackee -d fittrackee | gzip > ~/selfhost/fittrackee/backups/fittrackee-db-$(date +%F).sql.gz
tar -C ~/selfhost/fittrackee -czf ~/selfhost/fittrackee/backups/fittrackee-config-$(date +%F).tar.gz compose.yml .env uploads
ls -lh ~/selfhost/fittrackee/backups/
```

Assert: both exist and both are non-empty. Print both sizes. Nothing is stopped: `pg_dump`
snapshots a running database consistently.

Both sit on the same disk as the data, which is not a backup, and on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a folder their
sync service watches or a USB stick, and copy both there with `cp`. In Git Bash a Windows drive
is written `/d/Backups`, not `D:\Backups`. Assert: the user confirms both filenames are listed
there. If they have neither, say plainly that this install has no backup.

To restore, in this order. `cd ~/selfhost/fittrackee` and untar the config archive there first,
so compose.yml, .env and the tracks are back before any container starts: PostgreSQL takes
`POSTGRES_PASSWORD` from .env the moment it initialises an empty volume. Then
`docker compose down -v`, the one place `-v` belongs because it drops the old volume on purpose,
`docker compose up -d fittrackee-db`, wait 30 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T fittrackee-db psql -U fittrackee -d fittrackee`, then
`docker compose up -d`. Open one workout and check its map draws.

## 9. Updating later

New versions are listed at https://github.com/SamR1/FitTrackee/releases. Migrations run at
start-up, so upstream asks you to back up first. Take both artifacts, then edit the image line in
~/selfhost/fittrackee/compose.yml to the new tag and digest:

```bash
cd ~/selfhost/fittrackee
docker compose pull
docker compose up -d
docker compose logs --tail 30 fittrackee
```

Watch that log until the migrations settle, then re-run step 7's `/api/config` check and confirm
`version` matches the pinned tag.

## 10. What will probably go wrong

On an Apple Silicon Mac the first `docker compose up -d` looks like a hang. It is not: the
PostGIS image is amd64 and Docker Desktop is translating it instruction by instruction while
PostgreSQL initialises a cluster and FitTrackee runs every migration it has ever shipped. I gave
up at four minutes, came back, and found it healthy. Let step 7's loop run all forty attempts
before touching anything, and if it still fails read `docker compose logs --tail 40 fittrackee-db`
rather than restarting. Later starts take seconds.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8129 to 0.0.0.0 so a phone on the wifi can reach it. That puts a login form
  with no TLS on every network the user joins.
- Do not configure SMTP, and do not add Redis or the Dramatiq worker.
- Do not set `WEATHER_API_PROVIDER`, `WEATHER_API_KEY` or a keyed `TILE_SERVER_URL`. Each means
  a third-party account this install exists to avoid.
