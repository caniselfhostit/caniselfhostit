You are Claude Code on the user's own computer. There is no server and no Prompt Zero:
everything in this prompt runs on this machine and stays on it.

Run every command on this computer, in the shell you are already in. Nothing in this prompt
uses ssh.

Install AdventureLog 0.12.1, with the PostGIS database it stores trips in, under
~/selfhost/adventurelog, answering at http://localhost:8168.

## 1. Preflight

Say this to the user before step 2 runs; it decides whether they want this install at all.
AdventureLog answers only at http://localhost:8168, this computer and nowhere else, so the phone
that took the photographs cannot upload to it and nobody they travel with can open the trip.
Every picture arrives by being copied onto this machine and dragged into a browser.

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
2048 MB of RAM available and 10 GB free on the home disk: the first boot imports a world
geography dataset and upstream asks for 2 GB while it runs. PostGIS is required and its image is
linux/amd64 only, so an Apple Silicon Mac translates it under Docker Desktop, and a Linux machine
printing `aarch64` has no translation, so stop there. If RAM is under 2048 MB or disk under
10 GB, print both and stop.

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
mkdir -p ~/selfhost/adventurelog/media ~/selfhost/adventurelog/backups
ls -la ~/selfhost/adventurelog
```

Assert: `ls -la` shows `media` and `backups`. The backend container runs as root and writes
photographs and flags into `media`, so on Linux they end up root-owned but world-readable, which
lets step 8 archive them without sudo. On macOS and Windows Docker Desktop maps ownership itself.
The database lives in a volume Docker manages.

## 4. Secrets

Three secrets, all generated here: the PostgreSQL password, Django's `SECRET_KEY`, and the
password for the `admin` account the backend creates on first boot. Print none of them and keep
all three out of your summary and any log line.

```bash
umask 077
cat > ~/selfhost/adventurelog/.env <<EOF
PUBLIC_SERVER_URL=http://server:8000
ORIGIN=http://localhost:8168
BODY_SIZE_LIMIT=Infinity
PGHOST=db
POSTGRES_DB=adventurelog
POSTGRES_USER=adventurelog
POSTGRES_PASSWORD=$(openssl rand -hex 32)
SECRET_KEY=$(openssl rand -hex 48)
DJANGO_ADMIN_USERNAME=admin
DJANGO_ADMIN_PASSWORD=$(openssl rand -hex 24)
DJANGO_ADMIN_EMAIL=admin@localhost
PUBLIC_URL=http://localhost:8268
FRONTEND_URL=http://localhost:8168
CSRF_TRUSTED_ORIGINS=http://localhost:8168,http://localhost:8268
DEBUG=False
DISABLE_REGISTRATION=True
ENABLE_RATE_LIMITS=True
EOF
chmod 600 ~/selfhost/adventurelog/.env
umask 022
ls -l ~/selfhost/adventurelog/.env
```

Assert: the file exists with mode `-rw-------`. Git Bash ships openssl, so these lines run the
same everywhere. `PUBLIC_URL` is where the browser fetches photographs, which is why it names
8268, and `CSRF_TRUSTED_ORIGINS` lists both ports because the browser treats them as two
origins. `DEBUG` defaults to true in the image, so False matters even on a laptop. On Windows
those mode bits are advisory: the user's own account is the real boundary.

## 5. compose.yml

```bash
cat > ~/selfhost/adventurelog/compose.yml <<'EOF'
# AdventureLog · the deterministic fallback for the local path. Authored by
# caniselfhostit from the upstream documentation, not copied from a repository:
#   docker install .. https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/documentation/docs/install/docker.md
#   variables ....... https://github.com/seanmorley15/AdventureLog/blob/v0.12.1/.env.example
#
# Three services, every path relative to ~/selfhost/adventurelog/ so one file
# works on macOS, Linux and Windows. The names are load bearing:
# PUBLIC_SERVER_URL defaults to http://server:8000 and PGHOST is db. Two host
# ports: the backend serves photographs on 8268, the frontend the app on 8168.
# The database is a named volume because PostgreSQL chowns its data directory to
# a uid a home bind mount cannot grant on Windows. PostGIS is linux/amd64 only.
# Digests read 2026-08-07.
#
# NOT YET VERIFIED: no harness run has been recorded against this file.

services:
  db:
    image: postgis/postgis:16-3.5@sha256:7d7925e334fceb6079c0a5d150e925f192cde2cf1dd78767ca843e2996d39829
    platform: linux/amd64
    container_name: adventurelog-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - adventurelog-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U adventurelog -d adventurelog"]
      interval: 10s
      retries: 12
    # No `ports:` at all: 5432 is reachable only from the other containers.

  server:
    image: ghcr.io/seanmorley15/adventurelog-backend:v0.12.1@sha256:7c759efab1476841f7319776666e527bedd481cd71dbb08e51aaa5959f2a28eb
    container_name: adventurelog-backend
    restart: unless-stopped
    env_file: ./.env
    volumes:
      - ./media:/code/media
    ports:
      # Loopback only: nothing else on the wifi reaches 8268.
      - "127.0.0.1:8268:80"
    depends_on:
      db:
        condition: service_healthy

  web:
    image: ghcr.io/seanmorley15/adventurelog-frontend:v0.12.1@sha256:edd79220f0def1dbea5b5d56636621f6cfdb454db9c00a8ce436a8ab489c5e99
    container_name: adventurelog-frontend
    restart: unless-stopped
    env_file: ./.env
    ports:
      # Loopback only: nothing else on the wifi reaches 8168.
      - "127.0.0.1:8168:3000"
    depends_on:
      - server

volumes:
  adventurelog-pgdata:
EOF
cd ~/selfhost/adventurelog && docker compose config >/dev/null && echo "compose OK"
```

Assert: that prints `compose OK`: three services, two ports, one named volume.

## 6. Nothing is public

No reverse proxy, no certificate, no firewall rule, and each is a decision. There is no hostname
to resolve, and a certificate attests a public name nothing here has; browsers treat
http://localhost as a secure context anyway, so pages needing crypto still work. Nothing is
published beyond loopback: 8168 and 8268 bind to 127.0.0.1, not the user's phone, not a laptop on
the wifi, not the internet. Confirm it:

```bash
grep -c '"127.0.0.1:' ~/selfhost/adventurelog/compose.yml
```

Assert: that prints `2`, the frontend port and the backend port. PostgreSQL publishes no host
port, so 5432 never appears.

## 7. Start and verify

The backend waits for PostgreSQL, migrates, creates the `admin` account from the three
`DJANGO_ADMIN_` values, then downloads the world country and region dataset and a flag for every
country before it serves anything. Minutes on a first boot, so the loop below is patient.

```bash
cd ~/selfhost/adventurelog
docker compose pull
docker compose up -d
for i in $(seq 1 60); do code=$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:8168/); echo "$i $code"; [ "$code" = 200 ] && break; sleep 10; done
curl -sS http://localhost:8168/ | grep -o '<title>[^<]*</title>'
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8268/admin/login/
curl -sS http://localhost:8268/auth/is-registration-disabled/
docker compose exec -T db psql -U adventurelog -d adventurelog -tAc "SELECT count(*) FROM worldtravel_country;"
```

Assert all five, and print what you received for each: the loop ends on `200`; the title line
prints `<title>AdventureLog</title>`; the admin login page answers `200`, proving the backend
port serves; the registration endpoint prints `"is_disabled":true`, the security assert; the
count is at least `195`, so the world-data import finished rather than being killed. If any
misses, stop, run `docker compose logs --tail 40 server` and `docker compose logs --tail 20 db`,
and name the cause: a database never reporting healthy points at step 4, exit code 137 is memory
running out during the import, and on `port is already allocated` find what holds it with
`lsof -nP -iTCP:8168 -sTCP:LISTEN`. A running container is not success.

The first screen at http://localhost:8168 is the AdventureLog landing page with a `Login` button,
and http://localhost:8168/login shows `Username` and `Password` boxes and no sign-up link.

STOP: tell the user to read their admin password with
`grep DJANGO_ADMIN_PASSWORD ~/selfhost/adventurelog/.env`, put it in their password manager, sign
in at http://localhost:8168/login as `admin`, confirm the dashboard loads, and wait.
Do not continue until they confirm. It is the only credential here.

## 8. First backup and restore

Two artifacts: the database holds every trip, location and visit, the config archive the
photographs and the two files that rebuild the service.

```bash
cd ~/selfhost/adventurelog
docker compose exec -T db pg_dump -U adventurelog -d adventurelog | gzip > ~/selfhost/adventurelog/backups/adventurelog-db-$(date +%F).sql.gz
tar -C ~/selfhost/adventurelog -czf ~/selfhost/adventurelog/backups/adventurelog-config-$(date +%F).tar.gz compose.yml .env media
ls -lh ~/selfhost/adventurelog/backups/
```

Assert: both exist and both are non-empty. Print both sizes. The config archive is tens of
megabytes because the country flags are in it. Nothing is stopped: `pg_dump` snapshots a live
database consistently.

Both sit on the same disk as the data, which is not a backup: on a laptop the disk and the
machine fail together. Ask the user for a destination that leaves this computer, a sync folder or
a USB stick, and copy both there with `cp`. In Git Bash a Windows drive is written `/d/Backups`.
Assert: the user confirms both filenames are there. If not, say plainly this install has no
backup.

To restore, in this order. `cd ~/selfhost/adventurelog` and untar the config archive there first,
so compose.yml, .env and the photographs are back before any container starts: PostgreSQL takes
`POSTGRES_PASSWORD` from .env the moment it initialises an empty volume. Then
`docker compose down -v`, the one place `-v` belongs because it drops the old volume on purpose,
`docker compose up -d db`, wait 30 seconds, pipe `gunzip -c` on the `.sql.gz` into
`docker compose exec -T db psql -U adventurelog -d adventurelog`, then `docker compose up -d`.
Open a trip and check its photographs draw.

## 9. Updating later

New versions are listed at https://github.com/seanmorley15/AdventureLog/releases. Migrations run
at start-up and upstream asks you to back up first, so take both artifacts, then edit the two
image lines in ~/selfhost/adventurelog/compose.yml to the new tags and digests:

```bash
cd ~/selfhost/adventurelog
docker compose pull
docker compose up -d
docker compose logs --tail 30 server
```

Watch that log until the migrations settle, then re-run step 7's five checks. This project is on
0.x numbers and ships a few releases a year: read the release notes first.

## 10. What will probably go wrong

I rebooted this machine, opened http://localhost:8168 to add a weekend's photographs, and got a
connection error that looked like a lost database. Docker Desktop had not started with
the session, so nothing was listening on either port. `restart: unless-stopped` acts
only once the Docker daemon is up. Turn on Docker Desktop's start-at-login setting, and after a
reboot run `cd ~/selfhost/adventurelog && docker compose up -d` before concluding anything is
broken. The second start is fast: the world-data import already ran.

## 11. Out of scope

- Do not expose this to the internet.
- Do not configure port forwarding on the router.
- Do not add a reverse proxy or TLS.
- Do not rebind 8168 or 8268 to 0.0.0.0 for a phone on the wifi. That puts a login form with no
  TLS on every network the user joins.
- Do not set `GOOGLE_MAPS_API_KEY`, configure SMTP, or enable social login, Strava or Immich.
  Each means an account somewhere else, and none is needed to log a trip.
