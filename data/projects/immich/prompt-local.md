You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install Immich 3.1.0, with the PostgreSQL and machine-learning worker it needs, under
~/selfhost/immich, answering at http://localhost:8098.

## 1. Preflight

Say this to the user before step 2 runs, because it decides whether they want this install.
Immich will answer on http://localhost:8098, this computer and nothing else. Their phone cannot
reach it, so the automatic camera backup that replaces Google Photos does not work here; photos
arrive by dragging them into the browser. They get a private library with search, faces and
albums, on one machine.

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
distribution ID and codename print next, for step 2. Upstream publishes a floor of 6 GB of RAM,
and this install runs the machine-learning container, so 6144 MB is a floor rather than a
suggestion. Budget 20 GB free on the home disk before a single photo. On macOS and Windows that
figure is the host's and Docker Desktop's VM takes its share, so give it at least 6 GB in
Settings first. If available RAM is under 6144 MB or free disk is under 20 GB, print both and
stop.

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
  https://www.docker.com/products/docker-desktop/ and install it, and wait until they confirm.
  Either way, then STOP: tell the user to open Docker Desktop once, accept its terms, and wait
  for the whale icon to say it is running. Do not continue until they confirm.
- Windows: run `winget install -e --id Docker.DockerDesktop`. If winget is missing or the
  install fails, STOP: tell the user to download Docker Desktop from the URL above and install
  it, and wait until they confirm. Docker Desktop configures WSL 2 itself and may ask for a
  reboot; if it does, STOP and tell the user to reboot and come back, this prompt resumes at
  this step. Then STOP: have the user open Docker Desktop, accept its terms, and confirm it
  says running.
- Linux, Debian or Ubuntu: install Docker Engine from download.docker.com's apt repository,
  with its signing key saved to a file first, never piped into a shell. The fence is guarded, a
  no-op on anything but a Linux with apt:

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

  Adding the user to the docker group is root-equivalent on this machine; say that to the user
  in one sentence, and tell them the group change lands at their next login.
- Linux, anything else: STOP. Tell the user to install Docker Engine and the compose plugin
  with their distribution's package manager, and to run this prompt again once `docker info`
  works.

Assert: `docker info` exits 0 and `docker compose version` prints a version. Do not continue
without both.

## 3. Layout

```bash
mkdir -p ~/selfhost/immich/data ~/selfhost/immich/backups
ls -la ~/selfhost/immich
```

Assert: `data` and `backups` both exist, owned by the user. `data` is the photo library. The one
directory needing a chown to the image's own uid is PostgreSQL's, and step 5 keeps it in a
Docker volume, so no ownership fix runs on any of the three systems.

## 4. Secrets

One secret, the PostgreSQL password. Generate it here, do not print it, and keep it out of your
summary and any log line. Hex, not base64: upstream restricts it to A-Za-z0-9.

```bash
umask 077
cat > ~/selfhost/immich/.env <<EOF
TZ=Etc/UTC
DB_USERNAME=immich
DB_DATABASE_NAME=immich
IMMICH_ALLOW_SETUP=true
DB_PASSWORD=$(openssl rand -hex 32)
EOF
chmod 600 ~/selfhost/immich/.env
umask 022
ls -l ~/selfhost/immich/.env
```

Assert: the file exists with mode `-rw-------`. On Windows those mode bits are advisory because
NTFS does not enforce them; the real boundary is the user's own account, which on a single-user
machine is the one that matters. `IMMICH_ALLOW_SETUP` is true only until step 7 closes it.

## 5. compose.yml

```bash
cat > ~/selfhost/immich/compose.yml <<'EOF'
# Immich · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker compose install . https://docs.immich.app/install/docker-compose
#   variable reference ..... https://docs.immich.app/install/environment-variables
#
# Four services on the computer you are sitting at. Paths are relative to
# ~/selfhost/immich/, so one file works on macOS, Linux and Windows. The
# database is upstream's VectorChord build, not stock postgres; its data
# directory is a named volume because that image chowns it to its own uid, which
# Docker Desktop cannot grant on a Windows home bind. The library stays a bind
# mount. Pins are upstream's for v3.1.0, re-read 2026-08-05, all multi-arch.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

name: immich

services:
  database:
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    container_name: immich_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_INITDB_ARGS: "--data-checksums"
    volumes:
      - immich-pgdata:/var/lib/postgresql/data
    shm_size: 128mb
    # The image brings its own postgresql.conf and health script. No `ports:`.

  redis:
    image: docker.io/valkey/valkey:9@sha256:8e8d64b405ce18f41b8e5ee20aa4687a8ed0022d1298f2ce31cdcf3a76e09411
    container_name: immich_redis
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping || exit 1"]
      interval: 10s
      retries: 12
    # No `ports:` either: the queue is spoken between containers only.

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:v3.1.0@sha256:5a0839dc5303cd7215bcd2180a26aed3af41675aefb3e75e5157e9f10ad16e6e
    container_name: immich_machine_learning
    restart: unless-stopped
    volumes:
      - model-cache:/cache
    # No env_file: it reads no DB_ or REDIS_ variable. The name is load-bearing:
    # the server looks for models at immich-machine-learning:3003.

  immich-server:
    image: ghcr.io/immich-app/immich-server:v3.1.0@sha256:b434cb9287eea1471c9974845914d4dd328c9c2d652e446ed4930f99944f0ceb
    container_name: immich_server
    restart: unless-stopped
    env_file: ./.env
    environment:
      DB_HOSTNAME: database
      REDIS_HOSTNAME: redis
    volumes:
      - ./data:/data
    ports:
      # Loopback only: no other device on the wifi can reach 8098.
      - "127.0.0.1:8098:2283"
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  model-cache:
  immich-pgdata:
EOF
cd ~/selfhost/immich && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule. No DNS, because there is no hostname to
resolve. No TLS, because a certificate attests a public name and nothing here has one; browsers
treat http://localhost as a secure context anyway, so pages needing crypto still work. No
firewall rule, because nothing is published beyond loopback.

8098 is bound to 127.0.0.1: not the phone, not a laptop on the same wifi, not the internet. That
is the point of this path and its whole cost. Confirm it:

```bash
grep -n '127.0.0.1' ~/selfhost/immich/compose.yml
```

Assert: one line, `- "127.0.0.1:8098:2283"`. PostgreSQL and Valkey publish no host port.

## 7. Start and verify

The pull is roughly 5 GB and the first database start builds its extensions. The loop allows
twelve minutes.

```bash
cd ~/selfhost/immich
docker compose pull
docker compose up -d
for i in $(seq 1 72); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8098/api/server/ping); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8098/api/server/ping
curl -sS http://localhost:8098/api/server/config
```

Assert all three and print what you received. The loop ends on `200`; the ping response is
exactly `{"res":"pong"}`, the string the container's own health script checks for; the config
response contains `"isInitialized":false`, so no account exists yet. If any misses, stop, run
`docker compose logs --tail 40 immich-server` and `docker compose logs --tail 20 database`, and
name the cause: a database that never reports healthy points at step 4, where an empty
`DB_PASSWORD` leaves PostgreSQL refusing to start; for `port is already allocated`, find what
holds 8098 with `lsof -nP -iTCP:8098 -sTCP:LISTEN`. A running container is not success.

The first screen at http://localhost:8098 shows the heading `Welcome to Immich` and a
`Getting Started` button.

STOP: tell the user to open http://localhost:8098, click `Getting Started`, and fill in the
`Admin Registration` form, and wait. Do not continue until they confirm.

Once they confirm, close setup permanently:

```bash
cd ~/selfhost/immich
sed -i.bak 's/^IMMICH_ALLOW_SETUP=true$/IMMICH_ALLOW_SETUP=false/' ~/selfhost/immich/.env
rm -f ~/selfhost/immich/.env.bak
docker compose up -d --force-recreate immich-server
sleep 30
curl -sS http://localhost:8098/api/server/config
grep '^IMMICH_ALLOW_SETUP=' ~/selfhost/immich/.env
```

Assert: the config response now contains `"isInitialized":true` and the grep prints
`IMMICH_ALLOW_SETUP=false`. Both must pass before you report success. The `.bak` suffix is there
because macOS `sed` requires one.

## 8. First backup and restore

Two artifacts, not interchangeable. Upstream is explicit that a database backup holds no photos
and no video: the photos are files under `data`.

```bash
cd ~/selfhost/immich
docker compose exec -T database pg_dump --clean --if-exists --dbname=immich --username=immich | gzip > ~/selfhost/immich/backups/immich-db-$(date +%F).sql.gz
tar -C ~/selfhost/immich -czf ~/selfhost/immich/backups/immich-config-$(date +%F).tar.gz compose.yml .env
ls -lh ~/selfhost/immich/backups/
```

Assert: both files exist and both are non-empty. Print both sizes. Nothing is stopped, because
`pg_dump` snapshots a running database consistently.

Both archives sit on the same disk as the photos, and on a laptop the disk and the machine fail
together. Ask the user for a destination that leaves this computer, a synced folder or an
external drive, and copy both archives and the whole `data` directory there with `cp -R`. Assert:
the user confirms all three are there. If they have nowhere to put them, say plainly that this
install has no backup.

To restore, in this order: untar the config archive into ~/selfhost/immich first, because
PostgreSQL reads `DB_PASSWORD` from .env the moment it initialises an empty volume; copy `data`
back; `docker compose down -v`, the one place `-v` belongs because it drops the old volume on
purpose; `docker compose up -d database`; wait a minute for healthy; then load the dump with
upstream's search_path rewrite:

```bash
gunzip --stdout ~/selfhost/immich/backups/immich-db-$(date +%F).sql.gz | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" | docker compose exec -T database psql --dbname=immich --username=immich --single-transaction --set ON_ERROR_STOP=on
```

Then `docker compose up -d` and open one photo. The dump knows where every photo is, `data` is
every photo, either alone rebuilds nothing.

## 9. Updating later

Releases are at https://github.com/immich-app/immich/releases, and the ones that break something
carry a changelog:breaking-change label on the matching discussion. Read the release notes
before pulling, every time: upstream does not backport patches and states that downgrading is
not supported. Take both backups, then edit the four image lines to their new tags and digests:

```bash
cd ~/selfhost/immich
docker compose pull
docker compose up -d
docker compose logs --tail 30 immich-server
```

Immich migrates its database on the way up, so watch that log until it settles, then re-run step
7's health check.

## 10. What will probably go wrong

I closed the laptop lid with an import running, opened it an hour later, and found half the
library with no thumbnails and a search returning nothing. Nothing was corrupted: Docker Desktop
had suspended with the machine, the queue stopped where it was, and Immich picked it up once the
containers were back. Turn on Docker Desktop's start-at-login setting, and after any sleep or
reboot run `cd ~/selfhost/immich && docker compose up -d` and read Administration > Job Queues
before concluding anything broke.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8098 to 0.0.0.0 so the phone app can reach it over wifi. That puts a library
  holding everything the user owns on every network they join.
- Do not enable hardware transcoding or machine-learning acceleration. Upstream's hwaccel files
  need a matched host driver; this install runs both on the CPU on purpose.
- Do not configure OAuth or SMTP. Immich needs neither.
